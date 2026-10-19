#!/usr/bin/env ruby
# Extracts the Europa Universalis V advance trees and every country's 1337
# starting position into eu5/ (data.json and PNG icons) for index.html.
# Definitions (advances, ages, modifiers, names) come straight from a local
# game install; the start state (what each country has researched, its
# development, population, treasury, armies...) comes from a *melted* save
# made at the start of a new game (pdx.tools' "Melt"), because the engine
# computes it at game start and it isn't in the game files. Re-run after a
# game patch (with a fresh 1337 save), then ./deploy.sh.
#
#   ruby extract.rb                                  # finds the game and saves/*_melted.eu5
#   ruby extract.rb "/path/to/Europa Universalis V/game" saves/my_start_melted.eu5
#
# Needs ImageMagick (`magick`) for the icons. The output is generated from
# Paradox's game files, so it's git-ignored and never committed.
require "json"
require "pathname"
require "set"
require "time"
require "open3"

# Game files are UTF-8 (names like "Württemberg"); don't depend on the shell's locale.
Encoding.default_external = Encoding::UTF_8

# Just enough of a parser for Paradox's Jomini script format: `key = value`,
# `key ?= { ... }`, comparisons, bare list items and # comments. A block is
# an array of [key, op, value] entries; bare list items have a nil key.
module Jomini
  TOKEN = /\s+|#[^\n]*|"(?:[^"\\]|\\.)*"|[?!<>=]=|[={}<>]|[^\s={}<>#"]+/

  def self.parse(text)
    tokens = text.delete_prefix("﻿").scan(TOKEN).reject { |t| t.match?(/\A\s/) || t.start_with?("#") }
    block, = parse_block(tokens, 0)
    block
  end

  def self.parse_block(tokens, i)
    entries = []
    while i < tokens.size && tokens[i] != "}"
      first = tokens[i]
      if tokens[i + 1]&.match?(/\A(?:[?!<>=]=|[=<>])\z/)
        op = tokens[i + 1]
        value, i = parse_value(tokens, i + 2)
        entries << [unquote(first), op, value]
      else
        value, i = parse_value(tokens, i)
        entries << [nil, nil, value]
      end
    end
    [entries, i + 1]
  end

  def self.parse_value(tokens, i)
    return parse_block(tokens, i + 1) if tokens[i] == "{"
    [unquote(tokens[i]), i + 1]
  end

  def self.unquote(token) = token.delete_prefix('"').delete_suffix('"')

  def self.values(block, key) = block.select { |k, _, _| k == key }.map(&:last)
  def self.value(block, key) = values(block, key).first
  def self.blocks(block) = block.select { |k, _, v| k && v.is_a?(Array) }.map { |k, _, v| [k, v] }

  # Every [key, value] at any depth.
  def self.walk(block, &visit)
    block.each do |k, _, v|
      visit.call(k, v)
      walk(v, &visit) if v.is_a?(Array)
    end
  end
end

class Eu5Extractor
  DEFAULT_GAME_DIRS = [
    "~/Library/Application Support/Steam/steamapps/common/Europa Universalis V/game",
    "/Volumes/*/Program Files (x86)/Steam/steamapps/common/Europa Universalis V/game",
    "/Volumes/*/SteamLibrary/steamapps/common/Europa Universalis V/game"
  ].freeze

  # Which advance file an advance came from decides which group it's shown in.
  GROUP_BY_FILE = {
    /\A0_age_of_/ => "core",
    /\A1_building_unlocks/ => "buildings",
    /\A2_(army|ship)_unlocks|\A3_(fort_level|supply_limit)/ => "military",
    /\A3_/ => "government",
    /\A4_choices_/ => "choices"
  }.freeze

  def initialize(game_dir, save_path, out_dir)
    @game = Pathname(game_dir)
    @save = Pathname(save_path)
    @out = Pathname(out_dir)
    raise "No Europa Universalis V game dir at #{@game}" unless @game.join("in_game/common/advances").directory?
    raise "No melted save at #{@save}" unless @save.file?
  end

  def call
    modifier_types
    ages = extract_ages
    advances = extract_advances
    countries = extract_countries(advances)
    units = extract_units(advances)
    buildings = extract_buildings(advances)
    write_icons(advances, countries, buildings)

    data = {
      generated_at: Time.now.utc.iso8601,
      game_version: @save_meta[:version],
      start_date: @save_meta[:date],
      ages: ages,
      advances: advances.map { |a| a.except(:icon_name, :file) },
      countries: countries,
      units: units,
      buildings: buildings
    }
    @out.mkpath
    @out.join("data.json").write(JSON.generate(data))
    puts "Wrote #{advances.size} advances, #{ages.size} ages, #{countries.size} countries, #{units.size} units, " \
         "#{buildings.size} buildings (start #{@save_meta[:date]}, v#{@save_meta[:version]}) to #{@out}"
  end

  private

  def read(path) = Jomini.parse(File.read(path, encoding: "UTF-8"))
  def files(dir, glob = "*.txt") = Dir[@game.join("in_game", "common", dir, glob).to_s].sort

  # ---- Localization ------------------------------------------------------
  def loc
    @loc ||= begin
      h = {}
      roots = [@game.join("main_menu/localization/english"), @game.join("in_game/localization/english")]
      roots.select(&:directory?).each do |root|
        Dir[root.join("**/*_l_english.yml").to_s].sort.each do |path|
          File.foreach(path, encoding: "UTF-8") do |line|
            h[$1] ||= $2 if line =~ /\A\s*([\w.\-]+):\d*\s+"(.*)"\s*(?:#.*)?\z/
          end
        end
      end
      h
    end
  end

  # Resolves $other_key$ references and drops the game's inline markup
  # (concept links [x|e], [ShowModifierTypeName('x')] calls, #bold ... #! styling).
  def text(key, depth = 0)
    raw = loc[key]
    return nil unless raw
    raw = raw.gsub(/\$([\w.\-]+)(?:\|[^$]*)?\$/) { depth < 5 ? (text($1, depth + 1) || humanize($1)) : $1 }
    raw = raw.gsub(/\[ShowModifierTypeName\('([^']*)'\)\]/) { modifier_name($1) }
             .gsub(/\[([\w.\-]+)\|[^\]]*\]/) { text($1, depth + 1) || humanize($1) }
             .gsub(/\[[^\]]*\]/, "")
             .gsub(/#\w+\s?|#!/, "").gsub("\\n", "\n")
    raw.strip
  end

  def humanize(id) = id.to_s.sub(/_(advance|culture|region|province|area)\z/, "").tr("_", " ").capitalize

  # ---- Modifiers ---------------------------------------------------------
  # key => { percent:, boolean:, already_percent:, decimals:, color: } from the
  # game's modifier definitions -- also how we tell effects apart from the
  # structural keys (age, requires, potential...) in an advance.
  def modifier_types
    @modifier_types ||= Dir[@game.join("main_menu/common/modifier_type_definitions/*.txt").to_s].sort.each_with_object({}) do |path, h|
      Jomini.blocks(read(path)).each do |key, body|
        h[key] = {
          percent: Jomini.value(body, "percent") == "yes",
          already_percent: Jomini.value(body, "already_percent") == "yes",
          boolean: Jomini.value(body, "boolean") == "yes",
          decimals: Jomini.value(body, "decimals")&.to_i,
          color: Jomini.value(body, "color")
        }.compact
      end
    end
  end

  def modifier_name(key) = text("MODIFIER_TYPE_NAME_#{key}") || humanize(key)

  # ---- Ages ----------------------------------------------------------------
  def extract_ages
    @ages = files("age").flat_map { |f| Jomini.blocks(read(f)) }.map do |id, body|
      { id: id, name: text(id) || humanize(id.sub(/\Aage_\d+_/, "age of ")), year: Jomini.value(body, "year")&.to_i }
    end
  end

  # ---- Advances ------------------------------------------------------------
  def extract_advances
    raw = {}
    files("advances").each do |path|
      file = File.basename(path)
      next if file.start_with?("_")
      Jomini.blocks(read(path)).each { |id, body| raw[id] = { file: file, body: body } }
    end

    advances = raw.map do |id, a|
      body = a[:body]
      gate = potential_gate(Jomini.value(body, "potential"))
      allow_institution = nil
      Jomini.walk(Jomini.value(body, "allow") || []) { |k, v| allow_institution ||= v.delete_prefix("institution:") if k == "has_embraced_institution" && v.is_a?(String) }
      {
        id: id,
        name: text(id) || humanize(id),
        desc: text("#{id}_desc"),
        age: Jomini.value(body, "age"),
        group: group_for(a[:file], body),
        for: Jomini.value(body, "for"),
        requires: Jomini.values(body, "requires").select { |r| raw.key?(r) },
        icon_name: Jomini.value(body, "icon"),
        file: a[:file],
        start_level: Jomini.value(body, "starting_technology_level")&.to_i,
        research_cost: Jomini.value(body, "research_cost")&.to_f,
        institution: allow_institution && (text(allow_institution) || humanize(allow_institution)),
        tags: gate[:tags],
        conditional: gate[:conditional],
        effects: effects(body),
        unlocks: unlocks(body)
      }.compact.reject { |_, v| v == [] || v == false }
    end
    advances.sort_by { |a| [a[:age].to_s, a[:id]] }
  end

  def group_for(file, body)
    GROUP_BY_FILE.each { |re, group| return group if file.match?(re) }
    "special"
  end

  # An advance gated by `potential` only applies to some countries. If the
  # gate is nothing but tag checks, we know exactly which ones.
  def potential_gate(potential)
    return { conditional: false } unless potential.is_a?(Array) && !potential.empty?
    tags = []
    pure = true
    Jomini.walk(potential) do |k, v|
      if %w[has_or_had_tag tag].include?(k) && v.is_a?(String) then tags << v
      elsif v.is_a?(String) && !%w[OR AND].include?(k) then pure = false
      end
    end
    pure && !tags.empty? ? { conditional: true, tags: tags.uniq } : { conditional: true }
  end

  def effects(body)
    body.filter_map do |k, _, v|
      next unless k && v.is_a?(String) && (t = modifier_types[k])
      if t[:boolean]
        { k: k, name: modifier_name(k) } if v == "yes"
      else
        { k: k, name: modifier_name(k), v: v.to_f, pct: (t[:percent] && !t[:already_percent]) || nil, good: t[:color] }.compact
      end
    end
  end

  def unlocks(body)
    body.filter_map do |k, _, v|
      next unless k&.start_with?("unlock_") && v.is_a?(String)
      kind = k.delete_prefix("unlock_")
      { kind: kind, id: v, name: text(v) || humanize(v) }
    end
  end

  # ---- The melted start save -----------------------------------------------
  # One streamed pass per section (sed does the line slicing at native speed);
  # a 335 MB save is ~24 million lines, of which we need a few million.
  def section_ranges
    @section_ranges ||= begin
      starts = []
      IO.popen(["grep", "-n", "-a", "-E", "^[A-Za-z_][A-Za-z0-9_]*=", @save.to_s]) do |io|
        io.each_line { |l| n, rest = l.split(":", 2); starts << [rest[/\A\w+/], n.to_i] }
      end
      total = IO.popen(["wc", "-l", @save.to_s], &:read).to_i
      starts.each_with_index.to_h { |(name, from), i| [name, [from, (starts[i + 1]&.last || total + 1) - 1]] }
    end
  end

  def each_save_line(section)
    from, to = section_ranges.fetch(section)
    IO.popen(["sed", "-n", "#{from},#{to}p", @save.to_s], encoding: "UTF-8") { |io| io.each_line { |l| yield l } }
  end

  def depth(line)
    i = 0
    i += 1 while line.getbyte(i) == 9
    i
  end

  def save_meta
    @save_meta ||= begin
      meta = {}
      File.foreach(@save, encoding: "UTF-8").first(80).each do |l|
        meta[:date] = $1 if l =~ /\A\tdate=([\d.]+)/
        meta[:version] = $1 if l =~ /\A\tversion="([^"]+)"/
      end
      meta
    end
  end

  def named_ids(section, key)
    names = {}
    cur = nil
    each_save_line(section) do |l|
      d = depth(l)
      if d == 2 && l =~ /\A\t\t(\d+)=\{/ then cur = $1.to_i
      elsif d == 3 && l =~ /\A\t\t\t#{key}="([^"]*)"/ then names[cur] = $1
      end
    end
    names
  end

  # location id (1-based) -> name: the engine numbers locations in the order
  # they appear in map_data/definitions.txt (checked against known capitals;
  # location_templates.txt has the same names but in a different order).
  def location_names = location_paths.keys

  # location name => [continent, subcontinent, region, area, province], in
  # definitions.txt order.
  def location_paths
    @location_paths ||= begin
      paths = {}
      walk = lambda do |block, trail|
        block.each do |k, _, v|
          if k && v.is_a?(Array) then walk.call(v, trail + [k])
          elsif k.nil? && v.is_a?(String) then paths[v] = trail
          end
        end
      end
      walk.call(Jomini.parse(File.read(@game.join("in_game/map_data/definitions.txt"), encoding: "UTF-8")), [])
      paths
    end
  end

  def extract_countries(advances)
    save_meta
    cultures = named_ids("culture_manager", "name")
    religions = named_ids("religion_manager", "name")
    tags = {}
    countries = {}
    cur = nil
    sub = nil
    blk = nil
    blk2 = nil
    each_save_line("countries") do |l|
      d = depth(l)
      if d == 1
        sub = l[/\A\t(\w+)=/, 1]
      elsif sub == "tags"
        tags[$1.to_i] = $2 if l =~ /\A\t\t(\d+)=(\w+)\s*\z/
      elsif sub == "database"
        if d == 2 && l =~ /\A\t\t(\d+)=\{/
          cur = countries[$1.to_i] = { id: $1.to_i, researched: [], currency: {}, rating: {}, ranks: {}, loc_rank: {} }
          blk = nil
        elsif d == 3
          if l =~ /\A\t\t\t(\w+)=\{\s*\z/ || l =~ /\A\t\t\t(color)=rgb \{\s*\z/ then blk = $1
          elsif l =~ /\A\t\t\t\}/ then blk = nil
          elsif l =~ /\A\t\t\t(\w+)=(.+?)\s*\z/
            blk = nil
            case $1
            when "country_name" then cur[:name_key] = $2.delete('"')
            when "country_type" then cur[:type] = $2
            when "capital" then cur[:capital] = $2.to_i
            when "primary_culture" then cur[:culture] = $2.to_i
            when "primary_religion" then cur[:religion] = $2.to_i
            when "great_power_rank" then cur[:great_power] = $2.to_i
            when "last_months_population" then cur[:population] = $2.to_f
            when "max_manpower" then cur[:max_manpower] = $2.to_f
            when "max_sailors" then cur[:max_sailors] = $2.to_f
            when "starting_technology_level" then cur[:level] = $2.to_i
            end
          end
        elsif d == 4
          blk2 = l =~ /\A\t{4}(\w+)=\{\s*\z/ ? $1 : nil
          case blk
          when "researched_advances" then cur[:researched] << $1 if l =~ /\A\t{4}(\w+)=yes/
          when "currency_data" then cur[:currency][$1] = $2.to_f if l =~ /\A\t{4}(\w+)=(-?[\d.]+)/
          when "color" then cur[:color] = l.split.map(&:to_i) if l =~ /\A\t{4}\d/
          when "economy" then cur[$1.to_sym] = $2.to_f if l =~ /\A\t{4}(income|expense)=(-?[\d.]+)/
          when "score" then cur[:score_place] = $1.to_i if l =~ /\A\t{4}score_place=(\d+)/
          when "owned_locations" then (cur[:owned] ||= []).concat(l.split.map(&:to_i))
          when "units" then cur[:armies] = (cur[:armies] || 0) + l.split.size
          when "amount_of_location_rank" then cur[:loc_rank][$1] = $2.to_i if l =~ /\A\t{4}(\w+)=(\d+)/
          end
        elsif d == 5 && blk == "score" && blk2 == "score_rating"
          cur[:rating][$1] = $2.to_f.round(2) if l =~ /\A\t{5}(ADM|DIP|MIL)=(-?[\d.]+)/
        end
      end
    end

    # Per owner: development and tax from the locations, regiments by type.
    dev = Hash.new(0.0)
    tax = Hash.new(0.0)
    cur = nil
    each_save_line("locations") do |l|
      d = depth(l)
      if d == 2 && l =~ /\A\t\t(\d+)=\{/ then cur = { owner: nil }
      elsif d == 3 && cur
        if l =~ /\A\t\t\towner=(\d+)/ then cur[:owner] = $1.to_i
        elsif l =~ /\A\t\t\tdevelopment=(-?[\d.]+)/ && cur[:owner] then dev[cur[:owner]] += $1.to_f
        elsif l =~ /\A\t\t\ttax=(-?[\d.]+)/ && cur[:owner] then tax[cur[:owner]] += $1.to_f
        end
      end
    end

    @regiments = Hash.new { |h, k| h[k] = Hash.new(0) }
    owner = nil
    each_save_line("subunit_manager") do |l|
      d = depth(l)
      if d == 3 && l =~ /\A\t\t\towner=(\d+)/ then owner = $1.to_i
      elsif d == 3 && owner && l =~ /\A\t\t\ttype=(\w+)/ then @regiments[owner][$1] += 1; owner = nil
      end
    end

    index = advances.each_with_index.to_h { |a, i| [a[:id], i] }
    list = countries.values.filter_map do |c|
      next if c[:owned].nil? || c[:owned].empty?
      tag = tags[c[:id]]
      capital = location_names[c[:capital].to_i - 1]
      path = location_paths[capital] || []
      land = @regiments[c[:id]].select { |t, _| t.start_with?("a_") }
      navy = @regiments[c[:id]].select { |t, _| t.start_with?("n_") }
      {
        tag: tag,
        name: text(tag) || text(c[:name_key].to_s) || tag,
        color: c[:color] && format("#%02x%02x%02x", *c[:color]),
        type: c[:type],
        capital: capital && (text(capital) || humanize(capital)),
        continent: path[0], subcontinent: path[1], region: path[2],
        culture: cultures[c[:culture]] && (text(cultures[c[:culture]]) || humanize(cultures[c[:culture]])),
        religion: religions[c[:religion]] && (text(religions[c[:religion]]) || humanize(religions[c[:religion]])),
        great_power: c[:great_power],
        level: c[:level],
        locations: c[:owned].size,
        rank: c[:loc_rank],
        development: dev[c[:id]].round(1),
        tax: tax[c[:id]].round(2),
        population: c[:population]&.round(1),
        income: c[:income]&.round(2), expense: c[:expense]&.round(2),
        gold: c[:currency]["gold"]&.round(1), prestige: c[:currency]["prestige"]&.round(1),
        stability: c[:currency]["stability"]&.round(1), army_tradition: c[:currency]["army_tradition"]&.round(2),
        max_manpower: c[:max_manpower]&.round(2), max_sailors: c[:max_sailors]&.round(2),
        scores: c[:rating].empty? ? nil : c[:rating],
        score_place: c[:score_place],
        armies: c[:armies],
        army: land, navy: navy,
        advances: c[:researched].filter_map { |id| index[id] }.sort
      }.compact.reject { |_, v| v == {} }
    end
    list.sort_by { |c| [-c[:development].to_f, c[:tag]] }
  end

  # ---- Units ---------------------------------------------------------------
  # Land units are all hidden templates in the files (EU5 forms regiments
  # from levies), so "a unit" here is any id that has a real name and a
  # category, minus the per-age templates (a_age_1_..., n_age_2_...).
  def extract_units(advances)
    raw = {}
    files("unit_types").each { |f| Jomini.blocks(read(f)).each { |id, body| raw[id] = body } }
    resolve = lambda do |id, seen = []|
      return {} if seen.include?(id) || !raw[id]
      parent = Jomini.value(raw[id], "copy_from")
      base = parent ? resolve.call(parent, seen + [id]) : {}
      raw[id].each { |k, _, v| base[k] = v if k && v.is_a?(String) }
      base
    end
    unlocked_by = unlockers(advances, "unit")
    ages = advances.to_h { |a| [a[:id], a[:age]] }
    started = Hash.new(0)
    @regiments.each_value { |types| types.each { |t, n| started[t] += n } }

    raw.keys.filter_map do |id|
      next if id.match?(/\A[an]_(age_\d|[a-z_]*template)/) || id.start_with?("a_") && !text(id)
      r = resolve.call(id)
      next unless r["category"] && (name = text(id))
      next if text("#{id}_desc")&.include?("just a template")
      navy = id.start_with?("n_")
      {
        id: id, name: name, desc: text("#{id}_desc"), kind: navy ? "navy" : "army",
        category: text(r["category"]) || humanize(r["category"]), category_id: r["category"],
        age: r["age"] || unlocked_by[id].filter_map { |a| ages[a] }.min, levy: r["levy"] == "yes" || nil,
        combat_power: r["combat_power"]&.to_f, max_strength: r["max_strength"]&.to_f,
        hull_size: r["hull_size"]&.to_f, cannons: r["cannons"]&.to_f, speed: r["movement_speed"]&.to_f,
        crew: r["crew_size"]&.to_f, transport: r["transport_capacity"]&.to_f,
        upgrades_to: r["upgrades_to"] && (text(r["upgrades_to"]) || humanize(r["upgrades_to"])),
        unlocked_by: unlocked_by[id], started: started[id].nonzero?
      }.compact
    end.sort_by { |u| [u[:kind], u[:age].to_s, u[:category_id], u[:name]] }
  end

  # id => advance ids that unlock it, for one kind of unlock_<kind> key.
  def unlockers(advances, kind)
    advances.each_with_object(Hash.new { |h, k| h[k] = [] }) do |a, h|
      (a[:unlocks] || []).each { |u| h[u[:id]] << a[:id] if u[:kind] == kind }
    end
  end

  # ---- Buildings -----------------------------------------------------------
  # Everything buildable in the ordinary course of play; the event-only,
  # unique and foreign buildings aren't part of the age progression.
  SKIPPED_BUILDING_FILES = /\A(event_only|unique_buildings|foreign|pirate|00_unique)/

  def extract_buildings(advances)
    unlocked_by = unlockers(advances, "building")
    ages = advances.to_h { |a| [a[:id], a[:age]] }
    files("building_types").flat_map do |path|
      next [] if File.basename(path).match?(SKIPPED_BUILDING_FILES)
      Jomini.blocks(read(path)).filter_map do |id, body|
        next unless Jomini.value(body, "category") && (name = text(id))
        sizes = %w[rural_settlement town city megalopolis].select { |s| Jomini.value(body, s) == "yes" }
        by = unlocked_by[id]
        {
          id: id, name: name, desc: text("#{id}_desc"),
          category: text(Jomini.value(body, "category")) || humanize(Jomini.value(body, "category").sub(/_category\z/, "")),
          sizes: sizes,
          max_levels: Jomini.value(body, "max_levels")&.then { |v| v.is_a?(String) && v.match?(/\A\d+\z/) ? v.to_i : nil },
          unlocked_by: by,
          age: by.map { |a| ages[a] }.compact.min,
          effects: effects(Jomini.value(body, "modifier") || [])
        }.compact.reject { |_, v| v == [] }
      end
    end.sort_by { |b| [b[:age].to_s, b[:category].to_s, b[:name]] }
  end

  # ---- Icons ---------------------------------------------------------------
  # Advance art, falling back to the icon of the building an advance unlocks;
  # only for advances the page can show (the generic trees, plus whatever
  # any country starts with) and every listed building. Mutates the advance
  # and building hashes with the :icon file name (without .png) if one exists.
  def write_icons(advances, countries, buildings)
    dir = @out.join("icons")
    dir.mkpath
    iface = @game.join("main_menu/gfx/interface")
    researched = countries.flat_map { |c| c[:advances] }.to_set
    jobs = {} # output name => source .dds
    building_icon = lambda do |id|
      src = iface.join("icons/buildings/#{id}.dds")
      src.file? ? (jobs["b_#{id}"] = src; "b_#{id}") : nil
    end

    advances.each_with_index do |a, i|
      next if a[:group] == "special" && !researched.include?(i)
      src = a[:icon_name] && iface.join("advance/#{a[:icon_name]}.dds")
      if src&.file?
        jobs[a[:icon_name]] = src
        a[:icon] = a[:icon_name]
      elsif (u = a[:unlocks]&.find { |x| x[:kind] == "building" })
        a[:icon] = building_icon.call(u[:id])
      end
    end
    buildings.each { |b| (i = building_icon.call(b[:id])) && b[:icon] = i }

    queue = Queue.new
    jobs.each { |name, src| queue << [name, src] }
    Array.new(8) do
      Thread.new do
        loop do
          name, src = queue.pop(true) rescue break
          out = dir.join("#{name}.png")
          next if out.file?
          system("magick", src.to_s, "-resize", "72x72", out.to_s, exception: false)
        end
      end
    end.each(&:join)
    # Drop references to icons that failed to convert.
    [advances, buildings].each { |list| list.each { |x| x.delete(:icon) if x[:icon] && !dir.join("#{x[:icon]}.png").file? } }
  end
end

if $PROGRAM_NAME == __FILE__
  game = ARGV[0] || Eu5Extractor::DEFAULT_GAME_DIRS.flat_map { |g| Dir[File.expand_path(g)] }.first
  save = ARGV[1] || Dir[File.join(__dir__, "saves", "*_melted.eu5")].first
  abort "Usage: ruby extract.rb [game dir] [melted save]" unless game && save
  Eu5Extractor.new(game, save, File.join(__dir__, "eu5")).call
end
