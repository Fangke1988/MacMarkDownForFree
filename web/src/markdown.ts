import MarkdownIt from 'markdown-it';
import DOMPurify from 'dompurify';
import katex from 'katex';
import hljs from 'highlight.js';

export const md = new MarkdownIt({html:false, linkify:true, breaks:false, highlight(code, lang) {
  return lang && hljs.getLanguage(lang) ? hljs.highlight(code,{language:lang}).value : '';
}});
md.inline.ruler.before('escape','math_inline',(state,silent) => {
  const start = state.pos;
  if (state.src[start] !== '$' || state.src[start+1] === '$') return false;
  let end = start+1;
  while ((end = state.src.indexOf('$',end)) >= 0 && state.src[end-1] === '\\') end++;
  if (end < 0 || end === start+1 || state.src.slice(start+1,end).includes('\n')) return false;
  if (!silent) {const token=state.push('math_inline','math',0); token.content=state.src.slice(start+1,end);}
  state.pos=end+1; return true;
});
md.block.ruler.before('fence','math_block',(state,start,end,silent) => {
  const line=state.src.slice(state.bMarks[start]+state.tShift[start],state.eMarks[start]);
  if (!line.startsWith('$$')) return false;
  let stop=start, content='';
  if (line.length>3 && line.trimEnd().endsWith('$$')) content=line.trimEnd().slice(2,-2);
  else {
    const lines=[line.slice(2)]; stop++;
    while(stop<end && !state.src.slice(state.bMarks[stop],state.eMarks[stop]).trim().endsWith('$$')) {lines.push(state.src.slice(state.bMarks[stop],state.eMarks[stop]));stop++;}
    if(stop>=end) return false;
    lines.push(state.src.slice(state.bMarks[stop],state.eMarks[stop]).trimEnd().slice(0,-2));content=lines.join('\n').trim();
  }
  if(silent) return true;
  const token=state.push('math_block','math',0);token.content=content;token.map=[start,stop+1];token.block=true;state.line=stop+1;return true;
});
function mathHTML(value:string,display:boolean) {
  try{return katex.renderToString(value,{displayMode:display,throwOnError:true,trust:false});}
  catch{return `<span class="render-error">公式语法错误：${md.utils.escapeHtml(value)}</span>`;}
}
md.renderer.rules.math_inline=(tokens,i)=>mathHTML(tokens[i].content,false);
md.renderer.rules.math_block=(tokens,i)=>`<div class="math-preview" data-line="${tokens[i].map?.[0] ?? 0}">${mathHTML(tokens[i].content,true)}</div>`;
const fence=md.renderer.rules.fence!;
md.renderer.rules.fence=(tokens,i,options,env,self)=>{
  const t=tokens[i],language=t.info.trim().split(/\s/)[0];
  if(language==='mermaid') return `<div class="diagram" data-line="${t.map?.[0] ?? 0}"><pre class="mermaid-source">${md.utils.escapeHtml(t.content)}</pre></div>`;
  return `<section class="code-preview" data-line="${t.map?.[0] ?? 0}"><div class="code-caption"><span>${md.utils.escapeHtml(language||'text')}</span><button class="copy-code">复制</button></div>${fence(tokens,i,options,env,self)}</section>`;
};
export type Heading={id:string; title:string; level:number; line:number};
export function headings(text:string):Heading[] {
  const tokens=md.parse(text,{}),seen=new Map<string,number>();
  return tokens.flatMap((t,i)=>{
    if(t.type!=='heading_open') return [];
    const title=tokens[i+1]?.content||'未命名章节';
    const slug=title.toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu,'').trim().replace(/\s+/g,'-')||'section';
    const count=seen.get(slug)||0;seen.set(slug,count+1);
    return [{id:count?`${slug}-${count}`:slug,title,level:Number(t.tag.slice(1)),line:t.map?.[0]||0}];
  });
}
export function render(text:string):string {
  const tokens=md.parse(text,{}), hs=headings(text); let hi=0;
  for(const t of tokens) {
    if(t.map && t.nesting!==-1) t.attrSet('data-line',String(t.map[0]));
    if(t.type==='heading_open') t.attrSet('id',hs[hi++].id);
  }
  for(let i=2;i<tokens.length;i++){
    const t=tokens[i];if(t.type!=='inline'||tokens[i-2].type!=='list_item_open'||!t.children?.[0])continue;
    const first=t.children[0],match=first.content.match(/^\[([ xX])\]\s+/);if(!match)continue;
    first.content=first.content.slice(match[0].length);
    const checkbox=md.parseInline('checkbox',{})[0].children![0];checkbox.type='html_inline';
    checkbox.content=`<input type="checkbox" disabled aria-label="任务状态"${match[1].toLowerCase()==='x'?' checked':''}> `;
    t.children.unshift(checkbox);
  }
  return DOMPurify.sanitize(md.renderer.render(tokens,md.options,{}),{ADD_ATTR:['data-line'],FORBID_TAGS:['style','script','iframe','object']});
}
export function unsafeReason(text:string):string|null {
  if (/^(?:\uFEFF)?(?:---|\+\+\+)\s*\r?\n/.test(text)) return '文档包含 Front Matter，已保留原文并使用源码编辑。';
  const outside=text.replace(/^(`{3,}|~{3,})[^\n]*\n[\s\S]*?^\1\s*$/gm,'');
  if(/<\/?[A-Za-z][^>]*>|<!--/.test(outside)) return '文档包含原始 HTML，使用源码编辑以完整保留。';
  if(/^\s*:::+|\[\[[^\]]+\]\]|\[\^[^\]]+\]|^\s*\[TOC\]\s*$/im.test(outside)) return '文档包含扩展语法，使用源码编辑以完整保留。';
  return null;
}
// Compare rendered meaning, not Markdown whitespace, before enabling visual editing.
export function equivalent(a:string,b:string):boolean {
  const clean=(value:string)=>{
    const el=document.createElement('div'); el.innerHTML=render(value);
    el.querySelectorAll('*').forEach(node=>{node.removeAttribute('data-line');node.removeAttribute('id');});
    return el.innerHTML.replace(/>\s+</g,'><').trim();
  };
  return clean(a)===clean(b);
}
