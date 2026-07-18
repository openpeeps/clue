import std/[os, json, strutils, sequtils, algorithm, tables]

import pkg/kapsis/interactive/prompts

import ./configs

type
  DocEntry = object
    name: string
    version: string
    description: string
    builtAt: string
    path: string

proc htmlEscape(s: string): string =
  s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")

proc `<`(a, b: DocEntry): bool =
  result = a.name < b.name
  if a.name == b.name:
    result = a.builtAt > b.builtAt

proc collectDocs(): seq[DocEntry] =
  withDocsDB do:
    let docsTable = getDocsTable()
    for (pk, row) in docsTable.allRows():
      result.add(DocEntry(
        name: row["name"].strVal,
        version: row["version"].strVal,
        description: row["description"].strVal,
        builtAt: row["built_at"].strVal,
        path: row["path"].strVal,
      ))
  result.sort()

proc generateOverview*() =
  ## Generate ~/.clue/docs/index.html with package list and Fuse.js search.
  let packages = collectDocs()
  if packages.len == 0:
    displayInfo("No documented packages to show in overview")
    return

  let searchIndex = %*packages.map(proc (p: DocEntry): JsonNode =
    %*{"name": p.name, "version": p.version,
       "description": p.description, "builtAt": p.builtAt,
       "url": p.path & "/index.html"}
  )
  writeFile(clueDocsPath / "search-index.json", $searchIndex)

  var pkgHtml = ""
  for p in packages:
    pkgHtml.add("""<div class="pkg">
  <h2><a href="""" & p.path & """/index.html">""" & p.name & """</a></h2>
  <span class="version">v""" & p.version & """</span>
  <p class="desc">""" & htmlEscape(p.description) & """</p>
  <span class="built">Built: """ & p.builtAt & """</span>
</div>""")

  let html = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Clue Documentation</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/fuse.js/7.0.0/fuse.min.js"></script>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#f5f5f7;color:#1d1d1f;line-height:1.6}
.container{max-width:800px;margin:0 auto;padding:40px 20px}
h1{font-size:2rem;font-weight:700;margin-bottom:8px}
.sub{color:#6e6e73;margin-bottom:32px}
#search{width:100%;padding:12px 16px;font-size:1rem;border:1px solid #d2d2d7;border-radius:8px;outline:none;margin-bottom:32px;background:#fff}
#search:focus{border-color:#0071e3}
.pkg{background:#fff;border-radius:12px;padding:20px;margin-bottom:16px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
.pkg h2{font-size:1.25rem;margin-bottom:4px}
.pkg h2 a{color:#1d1d1f;text-decoration:none}
.pkg h2 a:hover{color:#0071e3}
.pkg .version{font-size:.85rem;color:#6e6e73;display:inline-block;margin-bottom:8px}
.pkg .desc{color:#1d1d1f;margin-bottom:8px}
.pkg .built{font-size:.8rem;color:#6e6e73}
</style>
</head>
<body>
<div class="container">
<h1>Documentation</h1>
<p class="sub">Browse documentation for locally built Nim packages</p>
<input type="text" id="search" placeholder="Search packages..." autocomplete="off" autofocus>
<div id="list">
""" & pkgHtml & """
</div>
</div>
<script>
(async function(){
  const resp = await fetch('search-index.json');
  const data = await resp.json();
  const fuse = new Fuse(data, {keys:['name','version','description'],threshold:.4});
  const input = document.getElementById('search');
  const list = document.getElementById('list');
  function render(items){
    list.innerHTML = items.map(p => `<div class="pkg"><h2><a href="${p.url}">${p.name}</a></h2><span class="version">v${p.version}</span><p class="desc">${p.description}</p><span class="built">Built: ${p.builtAt}</span></div>`).join('');
  }
  input.addEventListener('input', function(){
    if(this.value.trim()===''){render(data);return}
    render(fuse.search(this.value).map(r=>r.item));
  });
})();
</script>
</body>
</html>"""

  writeFile(clueDocsPath / "index.html", html)
  displaySuccess("Generated docs overview at " & clueDocsPath / "index.html")
