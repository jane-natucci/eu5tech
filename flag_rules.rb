# Which coat of arms a country flies at the start. The game picks by running triggers ("a republic", "ruled by
# the house of Valois", "owns Barcelona") from common/flag_definitions; this runs the same triggers against the
# facts flag_facts.rb read from the start save. Anything it can't judge counts as "not true", which for a first
# day in 1337 is the right way. Checks it never understood are collected in `unknown` so none go unnoticed.
require "set"
require_relative "jomini"

class FlagRules
  AGE = "age_1_traditions" # every start is in the first Age

  attr_reader :unknown

  # facts: tag => the hash flag_facts.rb wrote. game: Pathname of the game's `game` folder.
  def initialize(game, facts)
    @facts = facts
    @unknown = Hash.new { |h, k| h[k] = Set.new }
    main = game.join("main_menu/common")
    @triggers = {}
    Dir[main.join("scripted_triggers/*.txt").to_s].sort.each do |f|
      Jomini.parse(File.read(f, encoding: "UTF-8")).each { |k, _, v| @triggers[k] = v if k && v.is_a?(Array) }
    end
    @lists = {}
    Dir[main.join("flag_definitions/*.txt").to_s].sort.each do |f|
      Jomini.parse(File.read(f, encoding: "UTF-8")).each { |k, _, v| @lists[k] = v if k && v.is_a?(Array) && !k.start_with?("@") }
    end
    read_cultures(game.join("in_game/common"))
  end

  # The coat-of-arms key `tag` flies: the valid flag definition with the highest priority, else the tag itself.
  def flag_coa(tag, known)
    @root = tag
    @temp = {}
    best = nil
    definitions(tag).each do |d|
      coa = Jomini.value(d, "coa")
      next unless coa.is_a?(String) && known.include?(coa)

      trigger = Jomini.value(d, "trigger")
      next unless trigger.nil? || holds?(trigger, country(tag)) == true

      priority = Jomini.value(d, "priority").to_f
      best = [ priority, coa ] if best.nil? || priority > best.first
    end
    # No valid definition (or no list at all): the country's own coat of arms, which the game keys by the base flag
    # the save records (China starts as the Yuan: flag YUA) and failing that by its tag.
    best ? best.last : (known.include?(@facts.dig(tag, "flag")) ? @facts[tag]["flag"] : tag)
  end

  def definitions(tag, seen = [])
    out = []
    [ tag, "DEFAULT" ].each do |name|
      list = @lists[name]
      next if list.nil? || seen.include?(name)

      Jomini.values(list, "includes").each { |inc| out.concat(definitions(inc, seen + [ name ])) if inc.is_a?(String) }
      out.concat(Jomini.values(list, "flag_definition").select { |d| d.is_a?(Array) })
    end
    out
  end

  private

  # --- Scopes: a country, a person, a dynasty, a culture, a religion -------------------------------------------------
  Scope = Struct.new(:kind, :key, :data)

  def country(tag) = (f = @facts[tag]) ? Scope.new(:country, tag, f) : nil
  def exists?(tag) = (f = @facts[tag]) && f["type"] == "Real" && f["owned"].any?

  def read_cultures(common)
    @culture_tags = {}
    @culture_groups = {}
    Dir[common.join("cultures/*.txt").to_s].each do |f|
      Jomini.parse(File.read(f, encoding: "UTF-8")).each do |k, _, v|
        next unless k && v.is_a?(Array)

        @culture_tags[k] = Jomini.value(v, "tags")&.map(&:last) || []
        @culture_groups[k] = Jomini.value(v, "culture_groups")&.map(&:last) || []
      end
    end
    @religion_tags = {}
    Dir[common.join("religions/*.txt").to_s].each do |f|
      Jomini.parse(File.read(f, encoding: "UTF-8")).each do |group, _, v|
        next unless group && v.is_a?(Array)

        v.each { |k, _, body| @religion_tags[k] = Jomini.value(body, "tags")&.map(&:last) || [] if k && body.is_a?(Array) }
      end
    end
  end

  # Moves from a scope to the scope a name points at (ruler, heir, dynasty, culture ...), or nil if there is none.
  def step(scope, name)
    return nil unless scope

    case name
    when "scope:actor" then country(@root)
    when "scope:overlord" then (o = @facts.dig(@root, "overlord", "tag")) && country(o)
    when /\Ac:(\w+)\z/ then country($1)
    when "overlord" then scope.kind == :country && (o = scope.data.dig("overlord", "tag")) && country(o)
    when "ruler", "heir"
      return nil unless scope.kind == :country && (p = scope.data[name])

      Scope.new(:person, scope.key, p)
    when "dynasty" then scope.kind == :person && scope.data["dynasty"] && Scope.new(:dynasty, scope.data["dynasty"], nil)
    when "culture" then (c = scope.data["culture"]) && Scope.new(:culture, c, nil)
    when "religion" then (r = scope.data["religion"]) && Scope.new(:religion, r, nil)
    when "capital" then scope.kind == :country && (c = scope.data["capital"]) && Scope.new(:location, c, nil)
    end || nil
  end

  def walk_path(scope, path)
    path.split(".").inject(scope) { |s, name| step(s, name) }
  end

  # --- Three-valued logic: true / false / nil (can't tell). A block is an AND of its entries. -------------------------
  def holds?(block, scope)
    results = block.reject { |k, _, _| k.nil? }.map { |k, op, v| entry(k, op, v, scope) }
    return false if results.include?(false)

    results.include?(nil) ? nil : true
  end

  def any?(block, scope)
    results = block.reject { |k, _, _| k.nil? }.map { |k, op, v| entry(k, op, v, scope) }
    return true if results.include?(true)

    results.include?(nil) ? nil : false
  end

  def negate(r) = r.nil? ? nil : !r

  SCOPE_KEY = /\A(?:scope:\w+|c:\w+|ruler|heir|dynasty|culture|religion|capital)(?:\.\w+)*\z/

  def entry(key, op, value, scope)
    if value.is_a?(Array) && key.match?(SCOPE_KEY) # `ruler ?= { ... }`, `scope:actor.ruler.dynasty = { ... }`
      inner = walk_path(scope || country(@root), key)
      return inner ? holds?(value, inner) : (op == "?=" ? false : nil)
    end

    return same?(scope, key) if value == "this" && key.match?(/\A(?:dynasty|c|culture|religion):\w+\z/) # `dynasty:valois_dynasty ?= this`
    return same_scope?(key, value, scope) if value.is_a?(String) && value.start_with?("scope:") && key.match?(SCOPE_KEY)

    case key
    when "OR" then any?(value, scope)
    when "AND" then holds?(value, scope)
    when "NOT", "NOR" then negate(any?(value, scope))
    when "always" then value == "yes"
    when "save_temporary_scope_as" then (@temp[value] = scope) && true
    when "custom_tooltip", "random_select_if_same_priority" then true
    when "this" then same?(scope, value)
    when "any_subject_or_below" then relatives(scope, true).then { |l| aggregate(l) { |s| holds?(value, s) } }
    when "any_subject" then relatives(scope, false).then { |l| aggregate(l) { |s| holds?(value, s) } }
    when "any_overlord_or_above" then overlords(scope).then { |l| aggregate(l) { |s| holds?(value, s) } }
    when "any_union_partner" then unions(scope).then { |l| aggregate(l) { |s| holds?(value, s) } }
    else
      @triggers.key?(key) && %w[yes no].include?(value) ? scripted(key, value, scope) : atom(key, op, value, scope)
    end
  end

  # `scope:overlord = scope:custom_overlord`: two ways of naming the same country.
  def same_scope?(key, value, scope)
    left = walk_path(scope || country(@root), key)
    right = @temp[value.delete_prefix("scope:")] || walk_path(country(@root), value)
    left && right ? (left.kind == right.kind && left.key == right.key) : false
  end

  def scripted(key, value, scope)
    r = holds?(@triggers[key], scope)
    r.nil? || value == "yes" ? r : !r
  end

  def aggregate(list)
    return false if list.empty?

    results = list.map { |s| yield s }
    results.include?(true) ? true : (results.include?(nil) ? nil : false)
  end

  def relatives(scope, deep)
    return [] unless scope&.kind == :country

    out = []
    queue = (scope.data["subjects"] || []).map { |s| s["tag"] }
    until queue.empty?
      t = queue.shift
      next if out.any? { |s| s.key == t } || !@facts[t]

      out << country(t)
      queue.concat((@facts[t]["subjects"] || []).map { |s| s["tag"] }) if deep
    end
    out
  end

  def overlords(scope)
    out = []
    tag = scope&.key
    while (o = @facts.dig(tag, "overlord", "tag")) && out.none? { |s| s.key == o }
      out << country(o)
      tag = o
    end
    out
  end

  def unions(scope)
    return [] unless scope&.kind == :country

    ((scope.data["subjects"] || []).select { |s| s["type"] == "personal_union" }.map { |s| s["tag"] } +
      [ scope.data.dig("overlord", "type") == "personal_union" ? scope.data.dig("overlord", "tag") : nil ]).compact.filter_map { |t| country(t) }
  end

  def same?(scope, value)
    return nil unless scope

    case value
    when /\Ac:(\w+)\z/ then scope.kind == :country ? scope.key == $1 : nil
    when /\Adynasty:(\w+)\z/ then scope.kind == :dynasty ? scope.key == $1 : nil
    when /\Aculture:(\w+)\z/ then scope.kind == :culture ? scope.key == $1 : nil
    when /\Areligion:(\w+)\z/ then scope.kind == :religion ? scope.key == $1 : nil
    end
  end

  def name_of(value) = value.to_s.sub(/\A[a-z_]+:/, "")

  # The leaf checks.
  def atom(key, op, value, scope)
    c = scope&.kind == :country ? scope.data : nil
    case key
    when "government_type" then c && c["government"] == name_of(value)
    when "has_reform" then c && c["reforms"].include?(name_of(value))
    when "current_age" then value == AGE
    when "current_date" then compare_date(op, value)
    when "country_rank" then c && c["rank"] == name_of(value)
    when "country_exists", "exists" then existence(value)
    when "has_or_had_tag" then scope&.kind == :country ? scope.key == value : nil
    when "owns" then c && c["owned"].include?(name_of(value))
    when "at_war" then c && c["at_war"] == (value == "yes")
    when "scope_type" then scope && (value == scope.kind.to_s || (value == "country" && scope.kind == :country))
    when "has_ruler" then c && c["ruler"].nil? == (value == "no")
    when "has_heir" then c && c["heir"].nil? == (value == "no")
    when "is_subject_type" then c && c.dig("overlord", "type") == name_of(value)
    when "is_member_of_international_organization" then name_of(value) == "hre" ? c && c["hre_member"] == true : nil
    when "is_leader_of_international_organization" then name_of(value) == "hre" ? c && c["hre_leader"] == true : nil
    when "religion" then religion_check(scope, value)
    when "religion.group" then religion_group(scope, value)
    when "culture" then culture_check(scope, value)
    when "has_culture_group" then culture_group(scope, value)
    when "gfx_culture_applicable" then gfx(scope, value)
    when "has_variable" then false # variables are set by events and decisions during a game
    else unsure(key, scope)
    end
  end

  def existence(value)
    case value
    when /\Ac:(\w+)\z/ then exists?($1)
    when "scope:overlord" then !@facts.dig(@root, "overlord").nil?
    end
  end

  def compare_date(op, value)
    year = value.to_s[/\A(\d+)/, 1].to_i
    now = 1337
    case op
    when ">", ">=" then now > year
    when "<", "<=" then now < year
    end
  end

  def religion_check(scope, value)
    name = name_of(value)
    case scope&.kind
    when :country then scope.data["religion"] == name
    when :religion then scope.key == name
    when :person then scope.data["religion"] == name
    end
  end

  def religion_group(scope, value)
    return nil unless scope&.kind == :country

    scope.data["religion_group"] == name_of(value)
  end

  def culture_check(scope, value)
    return nil unless value.is_a?(String)

    name = name_of(value)
    case scope&.kind
    when :country, :person then scope.data["culture"] == name
    when :culture then scope.key == name
    end
  end

  def culture_group(scope, value)
    culture = case scope&.kind
              when :country, :person then scope.data["culture"]
              when :culture then scope.key
              end
    culture ? @culture_groups.fetch(culture, []).include?(name_of(value)) : nil
  end

  # `gfx_culture_applicable = christian_gfx`: the country's culture or religion carries that graphical tag.
  def gfx(scope, value)
    return nil unless scope&.kind == :country

    (@culture_tags.fetch(scope.data["culture"].to_s, []) + @religion_tags.fetch(scope.data["religion"].to_s, [])).include?(value)
  end

  def unsure(key, scope)
    @unknown[key] << (scope&.key || "?")
    nil
  end
end
