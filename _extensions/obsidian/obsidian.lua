--[==[
obsidian.lua — teach Quarto to read Obsidian Flavored Markdown.

(Long-bracket comment: the text below contains `]]`, which would close an
ordinary --[[ block early.)

Paired with, and useless without, this in _quarto.yml:

    from: markdown+wikilinks_title_after_pipe+mark
    filters:
      - at: pre-ast
        path: _extensions/obsidian/obsidian.lua

WHY A FILTER AND NOT A PREPROCESSOR

The obvious way to bridge Obsidian and Pandoc is to rewrite the text before
Pandoc sees it. That approach is wrong, and the reason is worth keeping: every
rule you would write is a regex over prose, and LaTeX is built from exactly the
characters those regexes hunt for. `^` is a block-id marker and a superscript.
`==` is an Obsidian highlight and a comparison in an aligned equation. `[[ ]]`
is a wikilink and a bracket matrix. A text-level pass cannot tell them apart,
so it silently corrupts formulas, and the damage surfaces as a LaTeX error far
from its cause.

A filter runs after parsing, on the syntax tree. By then math is a Math node
and code is a Code node -- opaque, and unreachable by any rule here. The bug
class is designed out rather than defended against.

Pandoc 3.x already does most of the work, which is why this file is small:

    [[Note]] / [[Note|alias]]   Link, tagged with a "wikilink" class
    ![[figure.png]]             Figure > Image, same class
    ==highlight==               Span .mark          (needs +mark)
    $$ ... $$                   Math DisplayMath    (untouched, always)

So what is left is the four things Pandoc has no concept of:

    [[@citekey]]        a CITATION, not a link -- see below
    ![[Note#Section]]   transclusion; Pandoc has no such notion
    > [!warning]        a callout, not a blockquote
    %%comment%%         a comment, not text

The citation case is the one that costs real work if you skip it. This repo's
vaults file literature notes as @<citekey>.md and link them [[@citekey]] (see
the vault AGENTS.md), so a wikilink beginning with @ is a bibliography entry. It
does not announce itself when it goes wrong: the link renders as plain text, the
reference never reaches the bibliography, and the paper's reference list is
quietly short.
]==]

local stringify = pandoc.utils.stringify

local MAX_EMBED_DEPTH = 3

local IMAGE_EXT = {
  png = true, jpg = true, jpeg = true, gif = true,
  svg = true, webp = true, pdf = true, bmp = true, tif = true, tiff = true,
}

-- Obsidian ships far more callout types than Quarto has, and Quarto drops an
-- unrecognized one silently, so the tail of this table matters as much as the
-- head. Left: everything Obsidian accepts, aliases included.
local CALLOUTS = {
  note = 'note', info = 'note', abstract = 'note', summary = 'note',
  tldr = 'note', example = 'note', quote = 'note', cite = 'note',
  todo = 'note', question = 'note', help = 'note', faq = 'note',
  tip = 'tip', hint = 'tip', success = 'tip', check = 'tip', done = 'tip',
  important = 'important',
  warning = 'warning', attention = 'warning',
  caution = 'caution', danger = 'caution', error = 'caution',
  failure = 'caution', fail = 'caution', missing = 'caution', bug = 'caution',
}

-- --- filesystem ------------------------------------------------------------

local function is_dir(path)
  return (pcall(pandoc.system.list_directory, path))
end

local function read_file(path)
  local fh = io.open(path, 'r')
  if not fh then return nil end
  local text = fh:read('a')
  fh:close()
  return text
end

--- Nearest ancestor of `start` containing a .obsidian directory.
local function find_vault(start)
  local dir = start
  for _ = 1, 40 do
    if dir == nil or dir == '' then return nil end
    if is_dir(pandoc.path.join{ dir, '.obsidian' }) then return dir end
    local parent = pandoc.path.directory(dir)
    if parent == dir then return nil end
    dir = parent
  end
  return nil
end

--- Index the vault once.
--
-- Obsidian addresses files by NAME, not by path, so resolving one link means
-- knowing every file in the vault. Doing that per link would be
-- O(links x files); once here is the difference between instant and not.
local notes, assets = {}, {}

local function index_vault(root)
  local function walk(dir, depth)
    if depth > 12 then return end
    local ok, entries = pcall(pandoc.system.list_directory, dir)
    if not ok then return end
    for _, name in ipairs(entries) do
      -- Skip dotted dirs: .obsidian is the app's own state and .quarto is a
      -- render cache. Both contain markdown that is not vault content.
      if name:sub(1, 1) ~= '.' then
        local full = pandoc.path.join{ dir, name }
        if is_dir(full) then
          walk(full, depth + 1)
        else
          local stem, ext = name:match('^(.*)%.([^.]+)$')
          if ext then
            ext = ext:lower()
            if ext == 'md' then
              notes[stem] = notes[stem] or full
              notes[name] = notes[name] or full
            elseif IMAGE_EXT[ext] then
              assets[name] = assets[name] or full
              assets[stem] = assets[stem] or full
            end
          end
        end
      end
    end
  end
  walk(root, 0)
end

--- Where the source document actually lives.
--
-- Not where Pandoc says it does. Quarto never hands Pandoc the file you wrote:
-- it stages a copy into /tmp/quarto-session-XXXX/quarto-input-XXXX.md and
-- passes that, so PANDOC_STATE.input_files points at a temp directory outside
-- the vault, and walking up from it finds no .obsidian, ever. The failure is
-- quiet in the worst way -- links still render as text and embeds still render
-- as a broken image, so the paper builds and is simply missing a section.
--
-- Quarto does export the real directory, and also chdirs into it. Plain
-- `pandoc note.md` exports neither but gives a usable input path. The filter
-- has to work under both runners, so try every anchor and take the first that
-- sits in a vault.
local function resolve_document()
  local candidates = {}
  local function add(d)
    if d and d ~= '' and not d:match('quarto%-session') then
      candidates[#candidates + 1] = d
    end
  end

  add(os.getenv('QUARTO_DOCUMENT_PATH'))       -- Quarto: the real source dir
  local input = (PANDOC_STATE.input_files or {})[1]
  add(input and pandoc.path.directory(input))  -- plain pandoc
  local ok, cwd = pcall(pandoc.system.get_working_directory)
  add(ok and cwd or nil)                       -- Quarto chdirs here too
  add(os.getenv('QUARTO_PROJECT_DIR'))         -- last resort: project root

  for _, dir in ipairs(candidates) do
    local found = find_vault(dir)
    if found then return dir, found end
  end
  return candidates[1] or '.', nil
end

local input_dir, vault = resolve_document()
if vault then index_vault(vault) end

--- A path Quarto can resolve, i.e. relative to the file being rendered.
local function relative_to_input(path)
  local ok, rel = pcall(pandoc.path.make_relative, path, input_dir)
  if ok and rel and rel ~= '' then return rel end
  return path
end

local function warn(msg)
  io.stderr:write('obsidian.lua: ' .. msg .. '\n')
end

-- --- transclusion ----------------------------------------------------------

--- The `## Heading` block of a document, up to the next same-or-higher heading.
local function extract_section(blocks, heading)
  local want = heading:lower():gsub('^%s+', ''):gsub('%s+$', '')
  local out, level = {}, nil
  for _, b in ipairs(blocks) do
    if b.t == 'Header' then
      if level then
        if b.level <= level then break end
      elseif stringify(b.content):lower() == want then
        level = b.level
        goto continue
      end
    end
    if level then out[#out + 1] = b end
    ::continue::
  end
  return out
end

--- Is this block a bare `![[...]]` pointing at a note rather than an image?
local function embed_target(block)
  local inner
  if block.t == 'Figure' then
    local first = block.content[1]
    if first and (first.t == 'Plain' or first.t == 'Para') then inner = first.content end
  elseif block.t == 'Para' or block.t == 'Plain' then
    inner = block.content
  end
  if not inner or #inner ~= 1 then return nil end

  local img = inner[1]
  if img.t ~= 'Image' or not img.classes:includes('wikilink') then return nil end

  local target = img.src
  local ext = target:match('%.([^.]+)$')
  if ext and IMAGE_EXT[ext:lower()] then return nil end
  return target
end

--- What an unresolved embed becomes: text the reader can see.
--
-- Leaving the Image node in place is not an option. The LaTeX writer turns it
-- into \includegraphics{Note#Section} and fails far from the cause, the HTML
-- writer into a broken <img>, and the Typst writer into #image("Note#Section"),
-- which Typst refuses to compile at all. Same rule as unmapped callouts:
-- losing the author's text is worse than losing the box.
local function missing(what, target)
  return pandoc.Strong{ pandoc.Str('[missing ' .. what .. ': ' .. target .. ']') }
end

--- Replace every bare ![[Note]] / ![[Note#Section]] with the note's content.
--
-- This is the one OFM feature with no Pandoc equivalent whatsoever, and the one
-- that matters most for a paper: it is how a vault keeps method and results
-- sections as separate notes and assembles them at render time. Resolved by
-- inlining, recursively, with a depth cap -- two notes embedding each other
-- would otherwise not terminate.
local function transclude(blocks, depth)
  local out = {}
  for _, b in ipairs(blocks) do
    local target = embed_target(b)
    if not target then
      out[#out + 1] = b
    elseif depth >= MAX_EMBED_DEPTH then
      warn('embed depth limit reached at [[' .. target .. ']] -- not inlined')
      out[#out + 1] = pandoc.Para{ missing('embed, depth limit', target) }
    else
      local name, section = target:match('^([^#]*)#?(.*)$')
      name = name:gsub('%s+$', '')
      local path = notes[name] or notes[name .. '.md']
      local text = path and read_file(path)
      if not text then
        warn('embedded note not found: ' .. target)
        out[#out + 1] = pandoc.Para{ missing('embed', target) }
      else
        local doc = pandoc.read(text, 'markdown+wikilinks_title_after_pipe+mark')
        local sub = doc.blocks
        if section ~= '' then sub = extract_section(sub, section) end
        for _, x in ipairs(transclude(sub, depth + 1)) do
          out[#out + 1] = x
        end
      end
    end
  end
  return out
end

-- --- comments --------------------------------------------------------------

--- Drop %% ... %% spans inside a paragraph.
local function strip_inline_comments(inlines)
  local out, skipping, changed = {}, false, false
  for _, el in ipairs(inlines) do
    local is_marker = el.t == 'Str' and el.text == '%%'
    -- The single-token form, %%like this%%, arrives as one Str.
    local whole = el.t == 'Str' and el.text:match('^%%%%.*%%%%$')
    if whole then
      changed = true
    elseif is_marker then
      skipping, changed = not skipping, true
    elseif not skipping then
      out[#out + 1] = el
    else
      changed = true
    end
  end
  if not changed then return nil end
  -- Removing a leading %% strands the space that followed it.
  while out[1] and (out[1].t == 'Space' or out[1].t == 'SoftBreak') do
    table.remove(out, 1)
  end
  while out[#out] and (out[#out].t == 'Space' or out[#out].t == 'SoftBreak') do
    table.remove(out)
  end
  return out
end

--- Drop whole blocks between a lone %% and the next lone %%, and any block
--- that inline stripping emptied out (a %%...%% on its own line leaves one).
local function strip_comment_blocks(blocks)
  local out, skipping = {}, false
  for _, b in ipairs(blocks) do
    local textish = b.t == 'Para' or b.t == 'Plain'
    local lone = textish and #b.content == 1 and b.content[1].t == 'Str'
      and b.content[1].text == '%%'
    if lone then
      skipping = not skipping
    elseif textish and #b.content == 0 then
      -- emptied by strip_inline_comments; drop it
    elseif not skipping then
      out[#out + 1] = b
    end
  end
  return out
end

-- --- callouts --------------------------------------------------------------

--- > [!warning] Title  ->  ::: {.callout-warning title="Title"}
local function callout(bq)
  local first = bq.content[1]
  if not first or (first.t ~= 'Para' and first.t ~= 'Plain') then return nil end

  local head = first.content[1]
  if not head or head.t ~= 'Str' then return nil end

  local kind, fold = head.text:match('^%[!([%w%-]+)%]([%+%-]?)$')
  if not kind then return nil end
  kind = kind:lower()

  -- The rest of the first line is the callout's title; everything after the
  -- first SoftBreak is body.
  local title, body_head, seen_break = {}, {}, false
  for i = 2, #first.content do
    local el = first.content[i]
    if not seen_break and (el.t == 'SoftBreak' or el.t == 'LineBreak') then
      seen_break = true
    elseif seen_break then
      body_head[#body_head + 1] = el
    elseif not (#title == 0 and el.t == 'Space') then
      title[#title + 1] = el
    end
  end

  local body = {}
  if #body_head > 0 then body[1] = pandoc.Para(body_head) end
  for i = 2, #bq.content do body[#body + 1] = bq.content[i] end

  local quarto = CALLOUTS[kind]
  if not quarto then
    -- An unmapped type must stay VISIBLE. Quarto renders an unknown callout
    -- class as nothing at all, so falling back to a blockquote is the only
    -- option that cannot lose the author's text.
    warn('unmapped callout type [!' .. kind .. '] -- kept as a blockquote')
    if #title > 0 then
      table.insert(body, 1, pandoc.Para{ pandoc.Strong(title) })
    end
    return pandoc.BlockQuote(body)
  end

  local attr = {}
  if #title > 0 then attr.title = stringify(pandoc.Para(title)) end
  -- `-` is Obsidian's start-collapsed marker; Quarto spells it `collapse`.
  if fold == '-' then attr.collapse = 'true'
  elseif fold == '+' then attr.collapse = 'false' end

  return pandoc.Div(body, pandoc.Attr('', { 'callout-' .. quarto }, attr))
end

-- --- links and images ------------------------------------------------------

local function wikilink(el)
  if not el.classes:includes('wikilink') then return nil end

  local target = el.target
  if target:sub(1, 1) == '@' then
    local id = target:sub(2):gsub('#.*$', '')
    return pandoc.Cite(
      { pandoc.Str('@' .. id) },
      { pandoc.Citation(id, 'NormalCitation') })
  end

  -- An internal note link has no meaning in a PDF. Flatten it to its display
  -- text rather than leaving a dangling link to a file the reader lacks.
  return el.content
end

local function wikiimage(el)
  if not el.classes:includes('wikilink') then return nil end

  local target = el.src
  local ext = target:match('%.([^.]+)$')
  if not (ext and IMAGE_EXT[ext:lower()]) then return nil end

  local path = assets[target] or assets[target:gsub('%.[^.]+$', '')]
  if not path then
    -- A path relative to the note that exists on disk is fine as it is.
    local fh = io.open(pandoc.path.join{ input_dir, target })
    if fh then fh:close(); return nil end
    warn('asset not found in vault: ' .. target)
    return missing('image', target)
  end

  el.src = relative_to_input(path)
  -- ![[figure.png|400]] sets a width; with the pipe extension that lands in
  -- the link's text, not its target.
  local caption = stringify(el.caption)
  local width = caption:match('^(%d+)$')
  if width then
    el.attributes.width = width .. 'px'
    el.caption = {}
  end
  return el
end

--- Drop the caption Pandoc invents for an image wikilink.
--
-- `![[figure.png]]` carries the filename as alt text, and Pandoc promotes alt
-- text on a lone image to a figure caption. Left alone, every figure in the
-- paper is captioned "figure.png" -- or, for `![[figure.png|400]]`, "400".
-- Obsidian has no caption syntax for embeds, so there is never anything here
-- worth keeping; a real caption is added in Quarto syntax instead.
local function wikifigure(fig)
  local first = fig.content[1]
  if not first or not first.content or #first.content ~= 1 then return nil end
  local img = first.content[1]
  if img.t ~= 'Image' or not img.classes:includes('wikilink') then return nil end
  fig.caption = pandoc.Caption({})
  return fig
end

local function strip_block_id(el)
  if el.text:match('^%^[%w%-]+$') then return {} end
  return nil
end

--- ==highlight== for Typst.
--
-- Pandoc's +mark extension yields a Span with class "mark". The HTML writer
-- turns that into <mark> and the LaTeX writer into \hl{}, but the Typst writer
-- drops the class and emits plain text. Measured on Quarto 1.8.27 / Pandoc
-- 3.6.3: `==hl==` rendered to PDF via Typst as bare "hl". Wrap it ourselves.
local function mark(el)
  if not el.classes:includes('mark') or not FORMAT:match('typst') then return nil end
  local out = { pandoc.RawInline('typst', '#highlight[') }
  for _, x in ipairs(el.content) do out[#out + 1] = x end
  out[#out + 1] = pandoc.RawInline('typst', ']')
  return out
end

-- --- pipeline --------------------------------------------------------------
--
-- Order is load-bearing. Transclusion runs first so that inlined content is
-- then processed by every later pass exactly like the host note's own -- an
-- embedded note's callouts, citations and images all work. Comments are
-- stripped next so a commented-out callout never becomes one.
return {
  { Pandoc = function(doc)
      if not vault then
        warn('not inside an Obsidian vault -- [[links]] and ![[embeds]] '
          .. 'cannot be resolved')
      end
      doc.blocks = transclude(doc.blocks, 0)
      return doc
    end },
  { Blocks = strip_comment_blocks, Inlines = strip_inline_comments },
  { BlockQuote = callout, Link = wikilink, Image = wikiimage,
    Figure = wikifigure, Span = mark, Str = strip_block_id },
}
