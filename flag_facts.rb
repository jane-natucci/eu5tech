# Reads, from a melted start save, the facts about each country that the game's flag rules look at (its
# government and reforms, its ruler's and heir's dynasty, culture and religion, its rank, the locations it owns,
# who is its overlord and who its subjects, whether it is at war, its place in the Holy Roman Empire) and writes
# eu5/flag_facts.json for extract_flags.rb. The output is the game's data, so it is gitignored, never committed.
#
#   ruby flag_facts.rb [game dir] [melted save]
require "json"
require "pathname"
require_relative "extract"

class FlagFacts
  def initialize(game, save, out_dir)
    @save = Pathname(save)
    @out = Pathname(out_dir)
    @location_names = Eu5Extractor.new(game, save, out_dir).send(:location_names)
  end

  def call
    sections = %w[culture_manager religion_manager dynasty_manager character_db countries diplomacy_manager war_manager international_organization_manager]
    state = Hash.new { |h, k| h[k] = {} }
    section = nil
    File.foreach(@save, encoding: "UTF-8") do |line|
      if line.getbyte(0) != 9 # a top-level line: a new section starts
        name = line[/\A(\w+)=\{/, 1]
        section = sections.include?(name) ? name : nil
        break if section.nil? && state.key?("war_manager") && name == "siege_manager" # nothing we need lies further on
        next
      end
      read_line(section, line, state) if section
    end
    write(state)
  end

  private

  def read_line(section, line, st)
    case section
    when "culture_manager" then named(line, st["cultures"], "name")
    when "religion_manager" then religion(line, st)
    when "dynasty_manager" then named(line, st["dynasties"], "key")
    when "character_db" then character(line, st)
    when "countries" then country(line, st)
    when "diplomacy_manager" then dependency(line, st)
    when "war_manager" then war(line, st)
    when "international_organization_manager" then organization(line, st)
    end
  end

  # database={ <id>={ name="..." ... } }: the id at depth 2 inside the section's own database, the field at depth 3.
  def named(line, into, key)
    d = depth(line)
    if d == 2 && line =~ /\A\t\t(\d+)=\{/ then @id = $1.to_i
    elsif d == 3 && line =~ /\A\t\t\t#{key}="([^"]*)"/ then into[@id] ||= $1
    end
  end

  def religion(line, st)
    d = depth(line)
    if d == 2 && line =~ /\A\t\t(\d+)=\{/ then @id = $1.to_i
    elsif d == 3 && line =~ /\A\t\t\tname="([^"]*)"/ then (st["religions"][@id] ||= {})["name"] = $1
    elsif d == 3 && line =~ /\A\t\t\tgroup=(\w+)/ then (st["religions"][@id] ||= {})["group"] = $1
    end
  end

  def character(line, st)
    d = depth(line)
    if d == 2 && line =~ /\A\t\t(\d+)=\{/ then @id = $1.to_i
    elsif d == 3 && line =~ /\A\t\t\tdynasty=(\d+)/ then (st["characters"][@id] ||= {})["dynasty"] = $1.to_i
    elsif d == 3 && line =~ /\A\t\t\tculture=(\d+)/ then (st["characters"][@id] ||= {})["culture"] = $1.to_i
    elsif d == 3 && line =~ /\A\t\t\treligion=(\d+)/ then (st["characters"][@id] ||= {})["religion"] = $1.to_i
    end
  end

  def country(line, st)
    d = depth(line)
    ids = st["country_tags"]
    if d == 1 then @sub = line[/\A\t(\w+)=/, 1]
    elsif @sub == "tags" then ids[$1.to_i] = $2 if line =~ /\A\t\t(\d+)=(\w+)\s*\z/
    elsif @sub == "database"
      if d == 2 && line =~ /\A\t\t(\d+)=\{/
        @cid = $1.to_i
        @block = nil
        @c = st["countries"][@cid] = { "owned" => [], "reforms" => [] }
      elsif d == 3
        @block = line[/\A\t\t\t(\w+)=\{\s*\z/, 1]
        if line =~ /\A\t\t\t(\w+)=([^{\s]+)\s*\z/
          case $1
          when "country_type" then @c["type"] = $2
          when "flag" then @c["flag"] = $2
          when "primary_culture" then @c["culture"] = $2.to_i
          when "primary_religion" then @c["religion"] = $2.to_i
          when "capital" then @c["capital"] = $2.to_i
          end
        end
      elsif d == 4 && @block == "government"
        @gov = line[/\A\t{4}(\w+)=\{\s*\z/, 1]
        @c["government"] = $1 if line =~ /\A\t{4}type=(\w+)\s*\z/
        @c["ruler"] = $1.to_i if line =~ /\A\t{4}ruler=(\d+)\s*\z/
        @c["heir"] = $1.to_i if line =~ /\A\t{4}heir=(\d+)\s*\z/
      elsif d == 6 && @block == "government" && @gov == "implemented_reforms" && line =~ /\A\t{6}object=(\w+)/
        @c["reforms"] << $1
      elsif d == 5 && @block == "country_rank_history" && line =~ /country_rank=(\w+)/
        @c["rank"] = $1
      elsif d == 4 && @block == "owned_locations" && line =~ /\A\t{4}\d/
        @c["owned"].concat(line.split.map(&:to_i))
      end
    end
  end

  # dependency={ first=<overlord id> second=<subject id> named_targets={ { flag=subject_type target={ object=<type> } } } }
  def dependency(line, st)
    if line =~ /\A\tdependency=\{/ then @dep = {}
    elsif @dep
      @dep["first"] = $1.to_i if line =~ /\A\t{2}first=(\d+)/
      @dep["second"] = $1.to_i if line =~ /\A\t{2}second=(\d+)/
      @dep["type"] = $1 if line =~ /\A\t{5}object=(\w+)/ && @dep["type"].nil?
      if line =~ /\A\t\}\s*\z/ && @dep["first"]
        (@deps ||= []) << @dep
        @dep = nil
      end
    end
  end

  def war(line, st)
    st["at_war"][$1.to_i] = true if line =~ /\A\t{5}country=(\d+)/
  end

  # The Holy Roman Empire: its members and its Emperor.
  def organization(line, st)
    d = depth(line)
    if d == 2 && line =~ /\A\t\t(\d+)=\{/ then @org = {}
    elsif d == 3 && line =~ /\A\t\t\ttype=(\w+)/ then (@org["type"] = $1)
    elsif d == 4 && @org && line =~ /\A\t{4}\d/ && !@org["members_done"] then (@org["members"] ||= []).concat(line.split.map(&:to_i))
    elsif d == 3 && line =~ /\A\t\t\tleader=(\d+)/ then @org["leader"] = $1.to_i
    end
    @org["members_done"] = true if @org && d == 3 && line =~ /\A\t\t\tleader=/
    @hre = { "members" => @org["members"] || [], "leader" => @org["leader"] } if @org && @org["type"] == "hre" && @org["leader"] && @hre.nil?
  end

  def depth(line)
    i = 0
    i += 1 while line.getbyte(i) == 9
    i
  end

  def write(st)
    tags = st["country_tags"]
    dyn = st["dynasties"]
    ch = st["characters"]
    person = lambda do |id|
      c = ch[id] or next nil
      { "dynasty" => dyn[c["dynasty"]], "culture" => st["cultures"][c["culture"]], "religion" => st["religions"][c["religion"]]&.fetch("name") }
    end
    out = {}
    st["countries"].each do |id, c|
      tag = tags[id] or next
      out[tag] = {
        "id" => id, "type" => c["type"], "flag" => c["flag"], "government" => c["government"], "reforms" => c["reforms"], "rank" => c["rank"],
        "culture" => st["cultures"][c["culture"]], "religion" => st["religions"][c["religion"]]&.fetch("name"),
        "religion_group" => st["religions"][c["religion"]]&.fetch("group"),
        "ruler" => c["ruler"] && person.call(c["ruler"]), "heir" => c["heir"] && person.call(c["heir"]),
        "capital" => @location_names[c["capital"].to_i - 1],
        "owned" => c["owned"].map { |l| @location_names[l - 1] }.compact,
        "at_war" => st["at_war"].key?(id)
      }.compact
    end
    (@deps || []).each do |dep|
      over = tags[dep["first"]]
      sub = tags[dep["second"]]
      next unless over && sub && out[over] && out[sub]

      (out[over]["subjects"] ||= []) << { "tag" => sub, "type" => dep["type"] }
      out[sub]["overlord"] = { "tag" => over, "type" => dep["type"] }
    end
    if (hre = @hre)
      hre["members"].each { |id| (t = tags[id]) && out[t] && out[t]["hre_member"] = true }
      (t = tags[hre["leader"]]) && out[t] && out[t]["hre_leader"] = true
    end
    @out.mkpath
    @out.join("flag_facts.json").write(JSON.generate(date: "1337.4.1", countries: out))
    puts "Wrote flag_facts.json: #{out.size} countries, #{out.count { |_, c| c["overlord"] }} subjects, #{out.count { |_, c| c["at_war"] }} at war"
  end
end

if $PROGRAM_NAME == __FILE__
  game = ARGV[0] || Eu5Extractor::DEFAULT_GAME_DIRS.flat_map { |g| Dir[File.expand_path(g)] }.first
  save = ARGV[1] || Dir[File.join(__dir__, "saves", "*_melted.eu5")].first
  abort "Usage: ruby flag_facts.rb [game dir] [melted save]" unless game && save
  FlagFacts.new(game, save, File.join(__dir__, "eu5")).call
end
