require 'rbbt-util'
require 'rbbt/workflow'
require 'rbbt/resource'
require 'rbbt/util/cmd'
require 'rbbt/sources/organism'
require 'rbbt/sources/uniprot'
require 'nokogiri'

$uniprot_variants = UniProt.annotated_variants.tsv :persist => true

Workflow.require_workflow 'translation'
module Kinase
  extend Workflow
  extend Resource

  class << self
    include LocalPersist
    local_persist_dir = File.join(File.dirname(__FILE__), '../cache')
  end

  def self.organism
    Organism.default_code("Hsa")
  end

  #def self.pdb_position(uniprot, position)
  #  require 'pg'
  #  pdbs = Postgres.pdb_for_uniprot(uniprot)
  #  pdbs.collect{|info|
  #    pdb, chain = info.values_at "pdb", "chain"
  #    pdb_position = Postgres.pdb_chain_and_position(uniprot, position, pdb, chain)
  #    next if pdb_position.first.nil?
  #    pdb_position = pdb_position.first["pos_pdb"]
  #    [pdb, chain, pdb_position]
  #  }.compact
  #end

  Kinase.software.opt.svm_light.claim :install, Rbbt.share.install.software.svm_light.find

  module MySql
    HOST = 'padme'
    PORT = nil
    OPTIONS = nil
    TTY = nil
    DBNAME = 'tm_kinase_muts'
    PDBNAME = 'kinmut'
    def self.kindriver_driver
      require 'mysql'
      @kindriver_driver ||= Object::Mysql.new('jabba.cnio.es', 'kindriver', 'kindriver', 'kindriver_db')
    end


    def self.snp2kin_driver(uniprot, change)
      uni_id = Organism.protein_identifiers(Kinase.organism).index(:target => "UniProt/SwissProt ID", :source => "UniProt/SwissProt Accession", :persist => true)[uniprot]
      raise "No UniProt/SwissProt Identifiers for accession: #{uniprot}" unless uni_id
      mutation_id = [uni_id, change] * "."
      query =<<-EOT
SELECT
     m.mutant_id,
     m.rel_freq,
     m.validation,
     d.disease_desc,
     s.histology,
     s.cosmic_mut_id,
     s.pubmed_id,
     r.pubmed_id
FROM
     Samples as s,
     Mutant as m,
     Disease as d,
     Mutant_has_Reference as r
WHERE 
     m.mutant_id="#{mutation_id}" AND
     r.mutant_id=m.mutant_id AND
     m.disease_id=d.disease_id AND
     s.mutant_id=m.mutant_id
;
      EOT

      begin
        res = kindriver_driver.query(query)
      rescue Exception
        Log.exception $!
        @kindriver_driver = nil
        sleep 1
        retry
      end

      res
    end
  end

  module Postgres
    HOST = 'padme'
    PORT = nil
    OPTIONS = nil
    TTY = nil
    DBNAME = 'tm_kinase_muts'
    PDBNAME = 'kinmut'

    def self.driver
      require 'pg'
      @driver ||= PGconn.connect(:host => HOST, :port => PORT, :dbname => DBNAME, :user => 'tgi_usuarioweb_sololectura')
    end

    def self.pdb_driver
      require 'pg'
      @pdb_driver ||= PGconn.connect(:host => HOST, :port => PORT, :dbname => PDBNAME, :user => 'tgi_webuser')
    end


    def self.pdb_for_uniprot(uniprot)
      query = "select pdb,chain from acc2pdbchain where acc='#{ uniprot }';"

      times = 0
      begin
        res = pdb_driver.exec(query)
      rescue Exception
        @pdb_driver = nil
        times += 1
        retry if times < 3
        raise $!
      end

      res
    end

    def self.pdb_chain_and_position(uniprot, position, pdb, chain)
      query = "select pos_pdb from acc2pdbchain_mapping where acc='#{ uniprot }' and pdb='#{ pdb }' and chain='#{chain}' and pos_acc=#{position};"
      res = begin
              pdb_driver.exec(query)
            rescue
              @driver = nil
              retry
            end
      res
    end

    def self.snp2l(uniprot, position)
      begin
        query =<<-EOT
SELECT
tum.wt_aa,
tum.mutant_aa,
tum.pubmed_id,
tum.new_position,
tum.old_position,
td.type,
mm.type,
ts.line_content

FROM 
tm_updated_mentions tum,
tm_datasets td,
mapping_methods mm,
tm_sentences ts

WHERE 
tum.tm_dataset_id=td.id AND
tum.mapping_method_id=mm.id AND
tum.acc='#{uniprot}' AND
tum.new_position=#{position} AND
tum.oldtriplet=ts.oldtriplets

ORDER BY 
tum.new_position,
tum.wt_aa, 
tum.mutant_aa
;
        EOT
        res = driver.exec(query)
      rescue
        @driver = nil
        retry
      end

      res
    end

    def self.snp2db(uniprot, position)
      query =<<-EOT
SELECT 
cm.acc,
cm.seq_pos,
cm.wt,
cm.mutant,
cm.description,
ed.type 
FROM 
complementary_muts cm,
external_dbs ed
WHERE 
cm.external_db_id = ed.id AND
acc='#{uniprot}' AND
seq_pos=#{position} AND NOT 
ed.type = 'uniprot'
;
      EOT
      res = driver.exec(query).to_a

      $uniprot_variants[uniprot].zip_fields.each do |values|
        mutation = values["Amino Acid Mutation"]
        next unless mutation.scan(/\d+/).first.to_i == position.to_i

        wt, _position, mut = mutation.match(/(.*?)(\d+)(.*)/).values_at 1, 2, 3
        mut = mut[-1].chr

        type, disease, snp = values.values_at("Type of Variant", "Disease", "SNP ID")
        if type == "Disease"
          description = "Disease: #{disease}"
        else
          description = "Polymorphism"
        end

        if snp and not snp.empty? and not snp == "-"
          snp_url = "http://www.ncbi.nlm.nih.gov/SNP/snp_ref.cgi?type=rs&rs=#{snp.sub(/rs/,'')}"
          description << " - (<a href='#{snp_url}'>#{ snp }</a>)" 
        end

        res << {
          :wt => wt,
          :seq_pos => position,
          :acc => uniprot,
          :mutant => mut,
          :description => description,
          :type => 'uniprot'
        }
      end
 
      res
    end
  end

  def self.ihop_interactions(uniprot)
    url = "http://ws.bioinfo.cnio.es/iHOP/cgi-bin/getSymbolInteractions?ncbiTaxId=9606&reference=#{uniprot}&namespace=UNIPROT__AC" 
    doc = Nokogiri::XML(Open.read(url))
    sentences = doc.css("iHOPsentence")
    sentences
  end

  def self.error_in_wt_aa?(protein, mutation)
    wt, pos, m = mutation.match(/([A-Z])(\d+)([A-Z])/i).values_at 1,2,3

    @@sequences ||= self.local_persist("sequence", :tsv, :source => data["KinaseAccessions_Group_Seqs.txt"].find) do 
      TSV.open data["KinaseAccessions_Group_Seqs.txt"].find, :type => :single, :fields => [2]
    end.tap{|o| o.unnamed = true; o}

    return false if @@sequences[protein].nil?

    if pos.to_i > @@sequences[protein].length
      real_wt = nil
    else
      real_wt = @@sequences[protein][pos.to_i - 1].chr
    end

    if wt == real_wt
      false
    else
      real_wt
    end
  end

  def self.get_features(job, protein, mutation)
    @feature_names ||= self.etc["feature.number.list"].find(:lib).tsv(:type => :single).sort_by{|key,value| key.to_i}.collect{|key, value| value}

    @patterns ||= {}

    patterns = @patterns[job] ||= TSV.open(job.step("patterns").path, :list, :key_field => @feature_names.length, :fix => Proc.new{|l| l.sub('#','').sub(/^\d+\t/,'').gsub(/\d+:/,'')}, :unnamed => true, :persist => true, :persist_file => job.step("patterns").path + '.tc' )
    patterns.key_field = "Protein Mutation"
    patterns.fields = @feature_names

    pattern = patterns[[protein, mutation] * "_"]
    info = {}

    @feature_pos = Misc.process_to_hash(patterns.fields){|l| (0..l.length - 1).to_a} 

    %w(SIFTscore SIFTscore_binned TDs_fscore_diff TDs_fscore_mt TDs_fscore_wt
    biochem_diffkdhydrophobicity firedb pfam_any phosphoelm sumGOLOR
    swannot_act_site swannot_act_site swannot_any swannot_binding
    swannot_carbohyd swannot_catalytic swannot_disulfid swannot_metal
    swannot_mod_res swannot_mutagen swannot_np_bind swannot_ptm swannot_signal
    swannot_site swannot_transmem).each do |key|
      info[key] = pattern[@feature_pos[key]]
    end

    info["uniprot_group"] = %w( class_uniprotgroup_AGC class_uniprotgroup_Atypical_ADCK
    class_uniprotgroup_Atypical_Alpha-type class_uniprotgroup_Atypical_FAST
    class_uniprotgroup_Atypical_PDK-BCKDK class_uniprotgroup_Atypical_PI3-PI4
    class_uniprotgroup_Atypical_RIO class_uniprotgroup_CAMK
    class_uniprotgroup_CK1 class_uniprotgroup_CMGC class_uniprotgroup_NEK
    class_uniprotgroup_Other class_uniprotgroup_RGC class_uniprotgroup_STE
    class_uniprotgroup_TK class_uniprotgroup_TKL).select{|key|
      pattern[@feature_pos[key]] == "1"
    }.first

    info["uniprot_group"].sub!(/class_uniprotgroup_/,'') unless info["uniprot_group"].nil?

    info["pfam"] = %w( pfam_PF00017 pfam_PF00018 pfam_PF00023 pfam_PF00027 pfam_PF00028
    pfam_PF00041 pfam_PF00047 pfam_PF00051 pfam_PF00063 pfam_PF00130
    pfam_PF00168 pfam_PF00169 pfam_PF00211 pfam_PF00226 pfam_PF00412
    pfam_PF00415 pfam_PF00433 pfam_PF00435 pfam_PF00454 pfam_PF00498
    pfam_PF00520 pfam_PF00531 pfam_PF00536 pfam_PF00560 pfam_PF00564
    pfam_PF00566 pfam_PF00567 pfam_PF00595 pfam_PF00611 pfam_PF00612
    pfam_PF00615 pfam_PF00621 pfam_PF00629 pfam_PF00659 pfam_PF00754
    pfam_PF00757 pfam_PF00779 pfam_PF00780 pfam_PF00787 pfam_PF01030
    pfam_PF01064 pfam_PF01094 pfam_PF01163 pfam_PF01392 pfam_PF01403
    pfam_PF01404 pfam_PF01833 pfam_PF02019 pfam_PF02185 pfam_PF02259
    pfam_PF02816 pfam_PF02828 pfam_PF03109 pfam_PF03607 pfam_PF03623
    pfam_PF06293 pfam_PF06479 pfam_PF07647 pfam_PF07686 pfam_PF07699
    pfam_PF07701 pfam_PF07714 pfam_PF08064 pfam_PF08163 pfam_PF08238
    pfam_PF08311 pfam_PF08332 pfam_PF08368 pfam_PF08477 pfam_PF08515
    pfam_PF08919 pfam_PF08926 pfam_PF09027 pfam_PF09042 pfam_PF10409
    pfam_PF10436 pfam_PF11555 pfam_PF11640 pfam_PF12063 pfam_PF12179
    pfam_PF12202 pfam_PF12474).select{|key|
      pattern[@feature_pos[key]] == "1"
    }.collect{|v| v.sub(/pfam_/,'')} * "|"

    info
  end

  input :list, :string, "Lista de mutations"
  task :input => :string do |list|
    proteins = []
    mutations = []

    list.split(/\n/).each{|l| 
      l.strip!
      if l.match(/(.*)[_ \t,]+(.*)/)
        prot, mut = $1, $2
        proteins << prot
        mutations << mut
      end
    }

    set_info :originals, proteins

    translated = Translation.job(:translate_protein, "", :proteins => proteins, :format => "UniProt/SwissProt Accession").exec

    set_info :translated, translated

    translations = Hash[*(translated.zip(proteins)).flatten]

    set_info :translations, translations

    translated_id = Translation.job(:translate_protein, "", :proteins => proteins, :format => "UniProt/SwissProt ID").exec

    set_info :translated_id, translated_id

    translations_id = Hash[*(translated.zip(translated_id)).flatten]

    set_info :translations_id, translations_id

    list = translated.zip(mutations)

    same_aa = list.select{|p,m| m[0] == m[-1]}

    set_info :synonymous, same_aa

    list.reject!{|p,m| m[0] == m[-1]}

    list.reject{|p,m| p.nil?}.collect{|p,m| [p,m] * "_"} * "\n"
  end

  dep :input
  task :patterns => :string do
    error_file = TmpFile.tmp_file
    patterns = CMD.cmd("perl -I '#{Kinase.bin.find}' '#{Kinase['bin/PatternGenerator.pl'].find}' '#{ step("input").path }' #{Kinase["etc/feature.number.list"].find} 2> '#{error_file}'").read
    error_text = Open.read(error_file)
    if not error_text.empty? and error_text =~ /is not a valid/
        set_info :filtered_out, error_text.split(/\n/).select{|l| l =~ /is not a valid/}.collect{|l| l.match(/(\w*) is not a valid/)[1]}
    else
      set_info :filtered_out, []
    end

    patterns
  end

  dep :patterns
  task :predict => :string do 
    CMD.cmd("#{Kinase["bin/run_svm.py"].find(:lib)} --m=e --o='#{path}.files' \
    --svm='#{Kinase['share/model/final.svm'].find}' --cfg='#{Kinase['etc/svm.config'].find}'", 
    "--ts=" => step("patterns").path)

    FileUtils.mv File.join(path + '.files', File.basename(step("patterns").path)), path

    raise "No predictions where made" if Open.read(path).empty?
    nil
  end

  dep :input
  task :other_predictors => :tsv do
    tsv = TSV.setup({}, :key_field => "Mutation", :fields => ["SIFT Score", "Mutation Assessor Score"], :type => :list)

    tsv
  end

  dep :predict
  dep :other_predictors
  task :default => :string do
    "DONE"
  end
end

if __FILE__ == $0
  uniprot, change= %w(P07949 A883F)
  Kinase::MySql.snp2kin_driver(uniprot, change).each do |r| iii r end
end
