# The crawlable side of the site, generated at deploy time from data.json: one real page per significant country
# (its own title, description, canonical address, structured data and a plain-text summary of how it starts),
# a sitemap, and the list of country links the front page carries. The page itself is one app; these pages are the
# same app opened on a country, so a search for "Castile EU5 1337" can land on Castile rather than on a hash.
#
#   ruby seo.rb <data.json> <index.html as deployed> <output dir>
#
# Writes <output dir>/index.html (the front page with its country links), <output dir>/country/<slug> (no
# extension: the deploy uploads them as text/html) and <output dir>/sitemap.xml. Needs only Ruby's standard library.
require "json"
require "cgi"
require "fileutils"
require "time"

Encoding.default_external = Encoding::UTF_8 # a CI runner may not have a UTF-8 locale
Encoding.default_internal = nil

SITE = "https://eu5tech.jane.berlin"
GAME = "Europa Universalis V"
SHORT = "EU5"
MIN_LOCATIONS = 10 # countries smaller than this get no page of their own: there'd be little to say about them

data = JSON.parse(File.read(ARGV[0], encoding: "UTF-8"))
template = File.read(ARGV[1], encoding: "UTF-8")
out = ARGV[2]
countries = data["countries"]
advances = data["advances"]
year = data["start_date"].to_s.split(".").first || "1337"

def h(text) = CGI.escapeHTML(text.to_s)
def n0(x) = x.to_f.round.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
def people(thousands)
  t = thousands.to_f
  t >= 1000 ? "#{format("%.2f", t / 1000).sub(/\.?0+\z/, "")} million" : "#{n0(t)} thousand"
end

def count(n, one, many = "#{one}s") = "#{n0(n)} #{n.to_i == 1 ? one : many}"
def slugify(name) = name.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")

pages = countries.select { |c| c["locations"].to_i >= MIN_LOCATIONS }.sort_by { |c| -c["development"].to_f }
used = {}
pages.each do |c|
  slug = slugify(c["name"])
  slug = "#{slug}-#{c["tag"].downcase}" if slug.empty? || used.key?(slug)
  used[slug] = c
  c["slug"] = slug
end
rank_of = pages.each_with_index.to_h { |c, i| [ c["tag"], i + 1 ] }

def person(p, role)
  return nil unless p

  abilities = p["adm"] ? ", administration #{p["adm"]}, diplomacy #{p["dip"]}, military #{p["mil"]}" : ""
  house = p["dynasty"] ? " of the house of #{p["dynasty"]}" : ""
  traits = p["traits"]&.any? ? " (#{p["traits"].join(", ").downcase})" : ""
  "#{role}: #{p["name"]}#{house}#{p["age"] ? ", aged #{p["age"]}" : ""}#{abilities}#{traits}"
end

# The text of a country's summary, shown on its page and used for its description.
def summary(c, advances, year)
  specials = c["advances"].map { |i| advances[i] }.select { |a| a["group"] == "special" }.map { |a| a["name"] }.first(8)
  regiments = c["army"]&.values&.sum.to_i
  ships = c["navy"]&.values&.sum.to_i
  facts = []
  facts << "#{c["name"]} (#{c["tag"]}) is #{c["great_power"] ? "great power ##{c["great_power"]}" : "ranked ##{c["power_rank"]}"} at the #{year} start of #{GAME}" \
           "#{c["capital"] ? ", with its capital at #{c["capital"]}" : ""}."
  facts << "Its people are #{c["culture"]}#{c["religion"] ? " and follow #{c["religion"]}" : ""}." if c["culture"]
  facts << "It holds #{n0(c["locations"])} locations with #{n0(c["development"])} development and about #{people(c["population"])} people."
  facts << "It starts with #{c["advances"].size} advances#{specials.any? ? " (among them #{specials.join(", ")})" : ""}, #{count(regiments, "regiment")} and #{count(ships, "ship")}."
  facts << "#{person(c["ruler"], "Ruler")}." if c["ruler"]
  facts << "#{person(c["heir"], "Heir")}." if c["heir"]
  facts
end

def description(c, year)
  bits = [ "#{c["name"]} at the #{year} start of #{GAME}" ]
  bits << "ruled by #{c["ruler"]["name"]}" if c["ruler"]
  bits << "#{n0(c["locations"])} locations, #{n0(c["development"])} development, #{c["advances"].size} starting advances"
  "#{bits.join(": ").sub(": ruled", ", ruled")}. Compare it with every other country."[0, 300]
end

# --- Rewrites of the page's own tags ---------------------------------------------------------------------------------
def retag(html, title:, description:, url:)
  html = html.sub(%r{<title>.*?</title>}m, "<title>#{h(title)}</title>")
  html = html.sub(/(<meta name="description" content=")[^"]*(")/, "\\1#{h(description)}\\2")
  html = html.sub(/(<link rel="canonical" href=")[^"]*(")/, "\\1#{url}\\2")
  html = html.sub(/(<meta property="og:url" content=")[^"]*(")/, "\\1#{url}\\2")
  html = html.gsub(/(<meta (?:property="og:title"|name="twitter:title") content=")[^"]*(")/, "\\1#{h(title)}\\2")
  html.gsub(/(<meta (?:property="og:description"|name="twitter:description") content=")[^"]*(")/, "\\1#{h(description)}\\2")
end

def ld(obj) = %(<script type="application/ld+json">#{JSON.generate(obj).gsub("</", "<\\/")}</script>)

links_to = lambda do |list|
  list.map { |c| %(<a href="/country/#{c["slug"]}">#{h(c["name"])}</a>) }.join(" · ")
end

# --- A page per country ----------------------------------------------------------------------------------------------
FileUtils.mkdir_p(File.join(out, "country"))
pages.each do |c|
  i = rank_of[c["tag"]] - 1
  near = (pages[[ i - 6, 0 ].max...i] + pages[(i + 1)..(i + 6)].to_a)
  facts = summary(c, advances, year)
  block = <<~HTML
    <details class="seo-about">
      <summary>About #{h(c["name"])} at the #{year} start</summary>
      #{facts.map { |f| "<p>#{h(f)}</p>" }.join("\n      ")}
      <p>Similar in size: #{links_to.call(near)}. <a href="/">All countries</a>.</p>
    </details>
  HTML
  title = "#{c["name"]} in #{SHORT} (#{year}): ruler, advances, army and economy – #{SHORT} Tech"
  url = "#{SITE}/country/#{c["slug"]}"
  html = retag(template, title: title, description: description(c, year), url: url)
  html = html.sub("<!--seo:about-->", block)
  html = html.sub("<!--seo:head-->", %(<meta name="initial-tag" content="#{c["tag"]}">\n  ) + ld({
    "@context" => "https://schema.org", "@type" => "WebPage", "name" => title, "url" => url,
    "description" => description(c, year), "inLanguage" => "en",
    "isPartOf" => { "@type" => "WebSite", "name" => "#{SHORT} Tech", "url" => "#{SITE}/" },
    "about" => { "@type" => "Thing", "name" => "#{c["name"]} in #{GAME}" },
    "breadcrumb" => { "@type" => "BreadcrumbList", "itemListElement" => [
      { "@type" => "ListItem", "position" => 1, "name" => "#{SHORT} Tech", "item" => "#{SITE}/" },
      { "@type" => "ListItem", "position" => 2, "name" => c["name"], "item" => url }
    ] }
  }))
  File.write(File.join(out, "country", c["slug"]), html, encoding: "UTF-8")
end

# --- The front page: unchanged to look at, just without the markers (the sitemap and the pages themselves carry the links) ---
front = template.sub("<!--seo:about-->", "")
front = front.sub("<!--seo:head-->", "")
File.write(File.join(out, "index.html"), front, encoding: "UTF-8")

# --- Sitemap -------------------------------------------------------------------------------------------------------------
stamp = Time.parse(data["generated_at"].to_s).utc.strftime("%Y-%m-%d") rescue Time.now.utc.strftime("%Y-%m-%d")
urls = [ [ "#{SITE}/", "1.0" ] ] + pages.map { |c| [ "#{SITE}/country/#{c["slug"]}", rank_of[c["tag"]] <= 30 ? "0.8" : "0.6" ] }
File.write(File.join(out, "sitemap.xml"), <<~XML)
  <?xml version="1.0" encoding="UTF-8"?>
  <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  #{urls.map { |u, p| "  <url><loc>#{u}</loc><lastmod>#{stamp}</lastmod><priority>#{p}</priority></url>" }.join("\n")}
  </urlset>
XML
puts "SEO: #{pages.size} country pages, sitemap with #{urls.size} addresses"
