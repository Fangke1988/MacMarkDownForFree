import './style.css';
import {Editor,rootCtx,defaultValueCtx,editorViewCtx,parserCtx,serializerCtx} from '@milkdown/kit/core';
import {commonmark,toggleStrongCommand,toggleEmphasisCommand,wrapInHeadingCommand} from '@milkdown/kit/preset/commonmark';
import {gfm,addRowAfterCommand,addColAfterCommand,setAlignCommand} from '@milkdown/kit/preset/gfm';
import {$node,$remark,$prose,callCommand,insert,replaceAll} from '@milkdown/kit/utils';
import {Plugin,TextSelection,NodeSelection} from '@milkdown/kit/prose/state';
import {deleteRow,deleteColumn,deleteTable} from '@milkdown/kit/prose/tables';
import {history} from '@milkdown/kit/plugin/history';
import {EditorState,Compartment,Text} from '@codemirror/state';
import {EditorView,keymap,lineNumbers,highlightActiveLine,drawSelection} from '@codemirror/view';
import {defaultKeymap,history as cmHistory,historyKeymap} from '@codemirror/commands';
import {markdown} from '@codemirror/lang-markdown';
import {syntaxHighlighting,defaultHighlightStyle} from '@codemirror/language';
import {oneDark} from '@codemirror/theme-one-dark';
import remarkMath from 'remark-math';
import katex from 'katex';
import mermaid from 'mermaid';
import DOMPurify from 'dompurify';
import {render,headings,unsafeReason,equivalent,md} from './markdown';

type Mode='reading'|'visual'|'source';
type Payload={text:string;token:string;mode:Mode;theme:string;plainText?:boolean;wordWrap?:boolean};
declare global {interface Window {EditorAPI:typeof api;webkit?:{messageHandlers:{editor:{postMessage:(message:unknown)=>void}}};__events:unknown[]}}
const $=<T extends HTMLElement=HTMLElement>(id:string)=>document.getElementById(id) as T;
const scroller=$('scroll'),reading=$('reading'),visual=$('visual'),source=$('source');
let text='',token='',mode:Mode='reading',theme='light',milk:Editor,cm:EditorView;
let loading=false,composing=false,ready=false,visualText='',sourceText='',reason:string|null=null;
let version=0,renderID=0,savedOffset=0,savedSelection={from:0,to:0},lastEdit=0;
let past:string[]=[],future:string[]=[],pendingComposed:string|null=null;
const cmTheme=new Compartment();
const cmWrap=new Compartment(),cmLanguage=new Compartment();
let plainText=false,wordWrap=true,searchTimer=0,resultsListed=false,resultsCollapsed=false;
type SearchMatch={from:number;to:number;line:number;column:number;lineStart:number;content:string};
let matches:SearchMatch[]=[];
function post(type:string,data:Record<string,unknown>={}) {
  const event={type,token,...data};
  if(window.webkit)window.webkit.messageHandlers.editor.postMessage(event);
  else {window.__events??=[];window.__events.push(event);}
}
function report(message:string) {$('notice').textContent=message;$('notice').hidden=!message;}
function stats(){
  const offset=mode==='source'&&cm?cm.state.selection.main.head:savedOffset;
  const currentLine=mode==='source'&&cm?cm.state.doc.lineAt(offset):null;
  const before=text.slice(0,offset),line=currentLine?.number??before.split('\n').length,col=currentLine?offset-currentLine.from+1:offset-(before.lastIndexOf('\n')+1)+1;
  post('stats',{words:(text.match(/[\p{Script=Han}]|[\p{L}\p{N}]+/gu)||[]).length,line,col,headings:plainText?[]:headings(text)});
}
function changed(next:string) {
  if(loading||next===text)return;
  if(composing){pendingComposed=next;return;}
  if(Date.now()-lastEdit>600||past.length===0){past.push(text);if(past.length>200)past.shift();}
  lastEdit=Date.now();future=[];text=next;version++;
  if(mode==='visual')visualText=next;if(mode==='source')sourceText=next;
  post('change',{text,version});stats();scheduleSearch();
}
const syncPlugin=$prose(ctx=>new Plugin({props:{nodeViews:{image(node){
  const dom=document.createElement('img');const update=(next:typeof node)=>{if(next.type.name!=='image')return false;dom.src=assetURL(next.attrs.src);dom.alt=next.attrs.alt||'';dom.title=next.attrs.title||'';return true;};update(node);return {dom,update,ignoreMutation:()=>true};
}}},view:()=>({update(view,previous){
  if(!view.state.doc.eq(previous.doc)&&!loading)changed(ctx.get(serializerCtx)(view.state.doc));
  $('table-tools').hidden=mode!=='visual'||!Array.from({length:view.state.selection.$from.depth},(_,i)=>view.state.selection.$from.node(i+1).type.name).includes('table');
}})}));
const mathPlugins=['inline_math','block_math'].map(name=>$node(name,()=>({
  group:name==='inline_math'?'inline':'block',inline:name==='inline_math',atom:true,attrs:{value:{default:''}},
  toDOM(node){const el=document.createElement(name==='inline_math'?'span':'div');el.className='math-node';el.dataset.value=node.attrs.value;el.dataset.display=String(name==='block_math');
    try{el.innerHTML=katex.renderToString(node.attrs.value,{displayMode:name==='block_math',throwOnError:true,trust:false});}catch{el.textContent=`公式语法错误：${node.attrs.value}`;el.classList.add('render-error');}return el;},
  parseDOM:[{tag:`${name==='inline_math'?'span':'div'}.math-node`,getAttrs:dom=>({value:(dom as HTMLElement).dataset.value||''})}],
  parseMarkdown:{match:node=>node.type===(name==='inline_math'?'inlineMath':'math'),runner:(state,node,type)=>{state.addNode(type,{value:node.value});}},
  toMarkdown:{match:node=>node.type.name===name,runner:(state,node)=>{state.addNode(name==='inline_math'?'inlineMath':'math',undefined,node.attrs.value);}}
})));
function assetURL(src:string){
  if(/^(https?:|data:image\/|mdasset:)/i.test(src))return src;
  if(/^[a-z][a-z\d+.-]*:/i.test(src))return '';
  return window.webkit?'mdasset://document/'+src.replace(/^\//,''):src;
}
function resolveImages(root:HTMLElement){if(root===visual)return;root.querySelectorAll('img').forEach(img=>{const raw=img.getAttribute('src')||'';if(!raw.startsWith('mdasset:'))img.src=assetURL(raw);img.onerror=()=>{img.title='图片未找到：'+raw;};});}
async function renderReading(){
  const current=++renderID;
  if(plainText){const pre=document.createElement('pre');pre.className='plain-text';pre.textContent=text;reading.replaceChildren(pre);return;}
  reading.innerHTML=text.trim()?render(text):'<div class="empty"><h1>从一页文字开始</h1><p>点击「编辑」开始写作，或打开一个 Markdown 文件。</p></div>';
  resolveImages(reading);
  mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme:theme==='dark'?'dark':'neutral',fontFamily:'-apple-system, PingFang SC, sans-serif'});
  for(const el of reading.querySelectorAll<HTMLElement>('.diagram')){
    const value=el.textContent||'';
    try{const result=await mermaid.render(`diagram-${current}-${Math.random().toString(36).slice(2)}`,value);
      if(current!==renderID)return;el.innerHTML=DOMPurify.sanitize(result.svg,{USE_PROFILES:{svg:true,svgFilters:true},ADD_TAGS:['foreignObject'],ADD_ATTR:['dominant-baseline']});
    }catch{if(current===renderID){el.innerHTML='';const error=document.createElement('pre');error.className='render-error';error.textContent='图表语法错误\n'+value;el.append(error);}}
  }
}
function offsetAtLine(line:number){return text.split('\n').slice(0,line).reduce((n,l)=>n+l.length+1,0);}
function captureReadingSelection(){
  const selection=window.getSelection();
  if(!selection?.anchorNode||!reading.contains(selection.anchorNode)){savedSelection={from:text.length,to:text.length};savedOffset=text.length;return;}
  const el=(selection.anchorNode.nodeType===1?selection.anchorNode:selection.anchorNode.parentElement) as HTMLElement;
  const block=el.closest<HTMLElement>('[data-line]');
  const start=offsetAtLine(Number(block?.dataset.line||0));
  const selected=selection.toString();let found=selected?text.indexOf(selected,start):-1;
  savedOffset=found>=0?found:start;savedSelection={from:savedOffset,to:found>=0?found+selected.length:savedOffset};
}
function visualOffset(pos:number){
  const view=milk.ctx.get(editorViewCtx),resolved=view.state.doc.resolve(pos);
  if(resolved.depth===0)return pos===0?0:text.length;
  let start=0,cursor=0;
  view.state.doc.forEach((node,p)=>{
    if(p>pos)return;
    const serialized=milk.ctx.get(serializerCtx)(view.state.schema.topNodeType.create(null,node)).trim();
    const found=text.indexOf(serialized,cursor);if(found>=0){start=found;cursor=found+serialized.length;}
  });
  const plain=resolved.parent.textBetween(0,resolved.parentOffset,'\n');
  if(plain){const found=text.indexOf(plain,start);if(found>=0)return found+plain.length;}
  return Math.min(text.length,start+resolved.parentOffset);
}
function locateVisual(offset:number,to=offset){
  const view=milk.ctx.get(editorViewCtx),lineText=text.slice(0,offset).split('\n').at(-1)||'';
  const row=text.split('\n')[text.slice(0,offset).split('\n').length-1]||'';
  const needle=row.replace(/^\s*(?:#{1,6}\s|>\s|[-*+]\s|\d+\.\s)/,'').replace(/[*`_]/g,'').trim();
  let pos=Math.min(view.state.doc.content.size,Math.max(1,offset)),found=false;
  view.state.doc.descendants((node,p)=>{if(found)return false;if(node.isTextblock && needle && node.textContent.includes(needle.slice(0,24))){pos=p+1+Math.min(node.content.size,lineText.replace(/^\s*#{1,6}\s/,'').length);found=true;}return !found;});
  pos=Math.min(pos,view.state.doc.content.size);
  view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(pos))));
  if(to>offset&&found){const end=Math.min(pos+to-offset,view.state.doc.content.size);view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc,pos,end)));}
}
async function setMode(next:Mode){
  if(!ready)return;
  if(document.body.classList.contains('printing'))return;
  if(composing){report('请先完成当前中文输入，再切换视图。');return;}
  if(plainText)next='source';
  const old=mode,scroll=scroller.scrollTop,ratio=scroll/Math.max(1,scroller.scrollHeight-scroller.clientHeight);
  if(old==='source'){savedOffset=cm.state.selection.main.head;savedSelection={from:cm.state.selection.main.from,to:cm.state.selection.main.to};}
  if(old==='visual'){const selection=milk.ctx.get(editorViewCtx).state.selection;savedSelection={from:visualOffset(selection.from),to:visualOffset(selection.to)};savedOffset=savedSelection.from;}
  if(next==='visual'){
    reason=unsafeReason(text);
    if(!reason){try{const parsed=milk.ctx.get(parserCtx)(text);const normalized=milk.ctx.get(serializerCtx)(parsed);if(!equivalent(text,normalized))reason='这份文档的部分语法无法无损转换，已使用源码编辑。';}catch{reason='文档含有暂不支持的语法，已使用源码编辑以保留原文。';}}
    if(reason)next='source';
  }
  mode=next;loading=true;
  try {
    if(mode==='visual'&&visualText!==text){milk.action(replaceAll(text));visualText=text;}
    if(mode==='source'&&sourceText!==text){cm.dispatch({changes:{from:0,to:cm.state.doc.length,insert:text}});sourceText=text;}
  }finally{loading=false;}
  reading.hidden=mode!=='reading';visual.hidden=mode!=='visual';source.hidden=mode!=='source';$('format').hidden=plainText||mode==='reading';$('table-tools').hidden=true;
  report(mode==='source'?(reason||''): '');
  if(mode==='reading')await renderReading();
  if(mode==='source'){const from=Math.min(savedSelection.from,cm.state.doc.length),to=Math.min(savedSelection.to,cm.state.doc.length);cm.dispatch({selection:{anchor:from,head:to}});cm.focus();}
  if(mode==='visual'){if(old!=='visual')locateVisual(savedSelection.from,savedSelection.to);milk.ctx.get(editorViewCtx).focus();resolveImages(visual);}
  requestAnimationFrame(()=>{scroller.scrollTop=ratio*Math.max(0,scroller.scrollHeight-scroller.clientHeight);});
  post('mode',{mode,reason:reason||''});stats();
}
async function load(payload:Payload){
  if(!ready)return;
  loading=true;text=payload.text;token=payload.token;version=0;past=[];future=[];lastEdit=0;visualText='\u0000';sourceText='\u0000';reason=null;savedOffset=0;savedSelection={from:0,to:0};pendingComposed=null;
  clearTimeout(searchTimer);matches=[];resultsListed=false;$('find-results').hidden=true;$('find').hidden=true;$('results-list').replaceChildren();$<HTMLInputElement>('query').value='';$('find-count').textContent='';
  plainText=payload.plainText??false;cm.dispatch({effects:cmLanguage.reconfigure(plainText?[]:markdown())});
  loading=false;setWordWrap(payload.wordWrap??wordWrap);setTheme(payload.theme);await setMode(payload.mode);scroller.scrollTop=0;
}
function setWordWrap(value:boolean){wordWrap=value;cm.dispatch({effects:cmWrap.reconfigure(value?EditorView.lineWrapping:[])});}
async function setDocumentType(value:boolean){plainText=value;reason=null;cm.dispatch({effects:cmLanguage.reconfigure(value?[]:markdown())});await setMode(mode);}
function setTheme(value:string){theme=value==='dark'?'dark':'light';document.documentElement.dataset.theme=theme;if(cm)cm.dispatch({effects:cmTheme.reconfigure(theme==='dark'?oneDark:[])});if(ready&&mode==='reading')void renderReading();}
async function restoreHistory(redo=false){
  if(composing)return;
  const stack=redo?future:past;if(!stack.length)return;
  (redo?past:future).push(text);text=stack.pop()!;lastEdit=0;version++;post('change',{text,version});await setMode(mode);stats();refreshSearch();
}
async function ensureEdit(){if(mode==='reading'){captureReadingSelection();await setMode('visual');}lastEdit=0;}
async function insertMarkdown(value:string,inline=false){
  await ensureEdit();
  if(mode==='source'){const sel=cm.state.selection.main;const prefix=inline?'':'\n\n',suffix=inline?'':'\n';cm.dispatch({changes:{from:sel.from,to:sel.to,insert:prefix+value+suffix},selection:{anchor:sel.from+prefix.length+value.length}});cm.focus();}
  else{milk.action(insert(value,inline));milk.ctx.get(editorViewCtx).focus();resolveImages(visual);}
}
function currentSelection(){
  if(mode==='source')return cm.state.sliceDoc(cm.state.selection.main.from,cm.state.selection.main.to);
  if(mode==='visual'){const s=milk.ctx.get(editorViewCtx).state;return s.doc.textBetween(s.selection.from,s.selection.to);}
  return window.getSelection()?.toString()||'';
}
type Field={name:string;label:string;value?:string;type?:string;min?:number;max?:number};
function dialog(title:string,fields:Field[],submit:(values:Record<string,string>)=>void,extra?:()=>void){
  const modal=$<HTMLDialogElement>('insert-dialog');$('dialog-title').textContent=title;$('dialog-fields').replaceChildren();
  for(const f of fields){const label=document.createElement('label');label.textContent=f.label;const input=document.createElement(f.type==='textarea'?'textarea':'input');input.name=f.name;input.value=f.value||'';
    if(input instanceof HTMLInputElement){input.type=f.type||'text';if(f.min!==undefined)input.min=String(f.min);if(f.max!==undefined)input.max=String(f.max);}label.append(input);$('dialog-fields').append(label);}
  if(extra){const button=document.createElement('button');button.type='button';button.textContent='选择本地图片…';button.onclick=()=>{modal.close();extra();};$('dialog-fields').append(button);}
  const textArea=$('dialog-fields').querySelector('textarea');
  if(textArea){const preview=document.createElement('div');preview.className='dialog-preview';$('dialog-fields').append(preview);let timer=0,previewID=0;
    const update=async()=>{const id=++previewID;const language=($('dialog-fields').querySelector('[name=lang],[name=language]') as HTMLInputElement)?.value;
      if(textArea.name==='value'){try{preview.innerHTML=katex.renderToString(textArea.value,{displayMode:true,throwOnError:true,trust:false});}catch{preview.textContent='公式语法错误';}}
      else if(language==='mermaid'){try{const result=await mermaid.render('dialog-'+Date.now(),textArea.value);if(id===previewID&&modal.open)preview.innerHTML=DOMPurify.sanitize(result.svg,{USE_PROFILES:{svg:true,svgFilters:true}});}catch{if(id===previewID)preview.textContent='图表语法错误';}}
      else{preview.textContent='';}};
    $('dialog-fields').oninput=()=>{clearTimeout(timer);timer=window.setTimeout(()=>void update(),250);};setTimeout(()=>void update(),0);
  }else $('dialog-fields').oninput=null;
  $('insert-form').onsubmit=event=>{event.preventDefault();const data=Object.fromEntries(new FormData($<HTMLFormElement>('insert-form'))) as Record<string,string>;modal.close();submit(data);};
  modal.showModal();($('dialog-fields').querySelector('input,textarea') as HTMLElement)?.focus();
}
function safeTarget(value:string){return !/^(?:javascript|vbscript|file|data):/i.test(value.trim());}
async function action(name:string){
  if(document.body.classList.contains('printing'))return;
  if((name==='undo'||name==='redo')&&(document.activeElement instanceof HTMLInputElement||document.activeElement instanceof HTMLTextAreaElement)){document.execCommand(name);return;}
  if($<HTMLDialogElement>('insert-dialog').open)return;
  if(name==='undo'){await restoreHistory();return;}if(name==='redo'){await restoreHistory(true);return;}
  if(['find','replace','findAll','findNext','findPrevious'].includes(name)){
    $('find').hidden=false;
    if(name==='findNext'||name==='findPrevious'){await findNext(name==='findPrevious');return;}
    if(name==='find'||name==='replace'){const selected=currentSelection();if(selected&&!selected.includes('\n'))$<HTMLInputElement>('query').value=selected;}
    refreshSearch();if(name==='findAll')findAll();
    const input=$<HTMLInputElement>(name==='replace'?'replacement':'query');input.focus();input.select();return;
  }
  if(plainText)return;
  await ensureEdit();const selected=currentSelection();
  if(name==='bold'||name==='italic'||name==='heading'){
    if(mode==='visual'){if(name==='heading')milk.action(callCommand(wrapInHeadingCommand.key,2));else milk.action(callCommand(name==='bold'?toggleStrongCommand.key:toggleEmphasisCommand.key));milk.ctx.get(editorViewCtx).focus();}
    else await insertMarkdown(name==='heading'?'## '+selected:(name==='bold'?'**':'*')+selected+(name==='bold'?'**':'*'),true);return;
  }
  if(name==='link'){
    let href='',linkRange:{from:number;to:number}|null=null;
    if(mode==='visual'){const state=milk.ctx.get(editorViewCtx).state;const mark=state.selection.$from.marks().find(m=>m.type.name==='link');if(mark){href=mark.attrs.href;state.doc.descendants((node,pos)=>{if(node.isText&&node.marks.some(m=>m.eq(mark))&&pos<=state.selection.from&&pos+node.nodeSize>=state.selection.from)linkRange={from:pos,to:pos+node.nodeSize};});}}
    const labelText=linkRange?milk.ctx.get(editorViewCtx).state.doc.textBetween((linkRange as {from:number;to:number}).from,(linkRange as {from:number;to:number}).to):selected;
    dialog('编辑链接',[{name:'label',label:'显示文字',value:labelText},{name:'url',label:'网页、文件路径或 #章节',value:href}],values=>{
      if(!values.url.trim()||!safeTarget(values.url)){report('请输入有效的网页、相对文件路径或章节链接。');return;}
      if(linkRange){const view=milk.ctx.get(editorViewCtx);view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc,linkRange.from,linkRange.to)));}
      void insertMarkdown(`[${(values.label||selected||values.url).replace(/[\[\]\\]/g,'\\$&')}](<${values.url.replace(/[<>\r\n]/g,'')}>)`,true);
    });return;
  }
  if(name==='image'){
    dialog('插入图片',[{name:'url',label:'图片地址（也可选择本地图片）'},{name:'alt',label:'替代文本'}],values=>{
      if(values.url&&safeTarget(values.url))void insertMarkdown(`![${values.alt.replace(/[\[\]\\]/g,'\\$&')}](<${values.url.replace(/[<>\r\n]/g,'')}>)`,true);
    },()=>post('chooseImage'));return;
  }
  if(name==='table'){
    dialog('创建表格',[{name:'rows',label:'数据行数',type:'number',value:'3',min:1,max:100},{name:'cols',label:'列数',type:'number',value:'3',min:1,max:20}],values=>{
      const rows=Math.min(100,Math.max(1,Number(values.rows)||3)),cols=Math.min(20,Math.max(1,Number(values.cols)||3));
      const row='| '+Array(cols).fill(' ').join(' | ')+' |';void insertMarkdown('| '+Array.from({length:cols},(_,i)=>`列 ${i+1}`).join(' | ')+' |\n| '+Array(cols).fill('---').join(' | ')+' |\n'+Array(rows).fill(row).join('\n'));
    });return;
  }
  if(name==='code'||name==='mermaid'){
    dialog(name==='code'?'插入代码':'插入 Mermaid 图表',[{name:'lang',label:'语言',value:name==='mermaid'?'mermaid':'javascript'},{name:'code',label:'内容',type:'textarea',value:name==='mermaid'?'flowchart LR\n    A[开始] --> B[完成]':selected}],values=>{const fence='`'.repeat(Math.max(3,...(values.code.match(/`+/g)||[]).map(s=>s.length+1)));void insertMarkdown(`${fence}${values.lang.replace(/[^\w+-]/g,'')}\n${values.code}\n${fence}`);});return;
  }
  if(name==='math')dialog('插入公式',[{name:'value',label:'LaTeX 公式',type:'textarea',value:selected||'E = mc^2'}],values=>{void insertMarkdown('$$\n'+values.value+'\n$$');});
}
function scheduleSearch(){
  clearTimeout(searchTimer);searchTimer=window.setTimeout(refreshSearch,100);
}
function refreshSearch(){
  clearTimeout(searchTimer);
  const query=$<HTMLInputElement>('query').value;
  matches=[];
  if(query){
    // Search the same line endings and offsets that CodeMirror uses, without rewriting the file.
    const doc=Text.of(text.split(/\r\n?|\n/)),value=doc.toString();
    const escaped=query.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
    const expression=new RegExp(escaped,$<HTMLInputElement>('match-case').checked?'gu':'giu');
    for(const match of value.matchAll(expression)){
      const from=match.index!,line=doc.lineAt(from);
      matches.push({from,to:from+match[0].length,line:line.number,column:[...value.slice(line.from,from)].length+1,lineStart:line.from,content:line.text});
    }
  }
  updateFindCount();
  for(const id of ['find-previous','find-next','replace-one','replace-all'])$<HTMLButtonElement>(id).disabled=matches.length===0;
  $<HTMLButtonElement>('find-all').disabled=!query;
  if(resultsListed)renderResults();
}
function updateFindCount(message=''){
  const selection=mode==='source'?cm.state.selection.main:savedSelection;
  const index=matches.findIndex(match=>match.from===selection.from&&match.to===selection.to);
  $('find-count').textContent=message||($<HTMLInputElement>('query').value?(index<0?`共 ${matches.length} 处`:`第 ${index+1} / ${matches.length} 处`):'输入文本，查找当前文件');
  $('results-list').querySelector('[aria-current=true]')?.removeAttribute('aria-current');
  $('results-list').querySelector(`[data-index="${index}"]`)?.setAttribute('aria-current','true');
}
function renderResults(){
  const fragment=document.createDocumentFragment();
  matches.forEach((match,index)=>{
    const item=document.createElement('li'),button=document.createElement('button'),position=document.createElement('span'),snippet=document.createElement('span'),mark=document.createElement('mark');
    button.dataset.index=String(index);position.className='result-position';position.textContent=`${match.line}:${match.column}`;
    snippet.className='result-snippet';
    const start=match.from-match.lineStart,left=Math.max(0,start-60),right=Math.min(match.content.length,start+(match.to-match.from)+100);
    snippet.append((left?'…':'')+match.content.slice(left,start));mark.textContent=match.content.slice(start,start+match.to-match.from);snippet.append(mark,match.content.slice(start+match.to-match.from,right)+(right<match.content.length?'…':''));
    button.append(position,snippet);button.title=`第 ${match.line} 行，第 ${match.column} 列`;button.onclick=()=>void selectMatch(index,true);item.append(button);fragment.append(item);
  });
  $('results-list').replaceChildren(fragment);$('results-empty').hidden=matches.length>0;
  $('results-empty').textContent=$<HTMLInputElement>('query').value?'没有匹配结果':'输入文本后点击「全文查找」';
  $('results-count').textContent=`当前文件 · ${matches.length} 处`;
  updateFindCount();
}
function findAll(){
  resultsListed=true;resultsCollapsed=false;$('find-results').hidden=false;updateResultsCollapsed();refreshSearch();
}
function updateResultsCollapsed(){
  $('results-body').hidden=resultsCollapsed;$('results-toggle').textContent=resultsCollapsed?'▸ 查找结果':'▾ 查找结果';$('results-toggle').setAttribute('aria-expanded',String(!resultsCollapsed));
}
async function selectMatch(index:number,focus=false){
  if(composing||!matches[index])return;
  if(mode!=='source')await setMode('source');
  const match=matches[index];if(!match)return;
  cm.dispatch({selection:{anchor:match.from,head:match.to},effects:EditorView.scrollIntoView(match.from,{y:'center'})});
  if(focus)cm.focus();updateFindCount();
}
async function findNext(previous=false){
  if(composing)return;
  refreshSearch();if(!matches.length)return;
  if(mode!=='source')await setMode('source');
  const selection=cm.state.selection.main;
  let index=matches.findIndex(match=>match.from>=selection.to);
  if(previous){index=-1;for(let i=matches.length-1;i>=0;i--){if(matches[i].to<=selection.from){index=i;break;}}}
  if(index<0)index=previous?matches.length-1:0;
  await selectMatch(index);
}
async function replaceFound(all=false){
  if(composing)return;
  refreshSearch();if(!matches.length)return;
  if(mode!=='source')await setMode('source');
  const replacement=$<HTMLInputElement>('replacement').value;
  if(!all){
    const selection=cm.state.selection.main;
    if(!matches.some(match=>match.from===selection.from&&match.to===selection.to))await findNext();
  }
  const selection=cm.state.selection.main;
  const targets=all?matches:matches.filter(match=>match.from===selection.from&&match.to===selection.to);
  if(!targets.length)return;
  const end=all?targets[0].from:targets[0].from+replacement.length;
  lastEdit=0;
  cm.dispatch({changes:targets.map(({from,to})=>({from,to,insert:replacement})),selection:{anchor:end}});
  lastEdit=0;refreshSearch();
  if(!all&&matches.length)await findNext();
  updateFindCount(`已替换 ${targets.length} 处 · 剩余 ${matches.length} 处`);
}
async function importFiles(files:FileList|File[]){
  if(plainText)return;
  await ensureEdit();
  for(const file of Array.from(files)){if(!file.type.startsWith('image/'))continue;const reader=new FileReader();reader.onload=()=>post('importImage',{name:file.name,data:String(reader.result).split(',')[1],mime:file.type});reader.readAsDataURL(file);}
}
const api={load,setMode,setTheme,setWordWrap,setDocumentType,action,focus:()=>{if(mode==='source')cm.focus();else if(mode==='visual')milk.ctx.get(editorViewCtx).focus();},insertImage:async(path:string)=>{await insertMarkdown(`![](<${path}>)`,true);},
  jump:async(line:number)=>{savedOffset=offsetAtLine(line);savedSelection={from:savedOffset,to:savedOffset};
    if(mode==='reading'){reading.querySelector<HTMLElement>(`[data-line="${line}"]`)?.scrollIntoView({block:'start'});}
    else if(mode==='source'){cm.dispatch({selection:{anchor:savedOffset},effects:EditorView.scrollIntoView(savedOffset,{y:'start'})});}
    else{locateVisual(savedOffset);milk.ctx.get(editorViewCtx).dispatch(milk.ctx.get(editorViewCtx).state.tr.scrollIntoView());}},
  flush:()=>{if(composing)return false;post('flush',{text,version});return true;},
  preparePrint:async()=>{await setMode('reading');document.body.classList.add('printing');reading.hidden=false;source.hidden=true;await renderReading();await Promise.all([...reading.querySelectorAll('img')].map(img=>img.complete?Promise.resolve():new Promise(resolve=>{img.onload=resolve;img.onerror=resolve;setTimeout(resolve,3000);})));await document.fonts.ready;return true;},
  printLayout:()=>{
    const width=720,height=Math.ceil(document.body.scrollHeight),pageHeight=(841.89-80)/(515.28/width);
    const protectedRects:{top:number;bottom:number}[]=[];
    const walker=document.createTreeWalker(reading,NodeFilter.SHOW_TEXT);let node:Node|null;
    while((node=walker.nextNode())){if(!node.textContent?.trim())continue;const range=document.createRange();range.selectNodeContents(node);for(const r of range.getClientRects())if(r.height>0)protectedRects.push({top:r.top+window.scrollY,bottom:r.bottom+window.scrollY});}
    reading.querySelectorAll('tr,img,svg,.katex-display').forEach(el=>{const r=el.getBoundingClientRect();protectedRects.push({top:r.top+window.scrollY,bottom:r.bottom+window.scrollY});});
    const cuts=[0];while(cuts.at(-1)!<height){const start=cuts.at(-1)!;let end=Math.min(height,start+pageHeight);
      for(let attempt=0;attempt<20;attempt++){const overlap=protectedRects.filter(r=>r.top<end&&r.bottom>end&&r.top>start+20).sort((a,b)=>a.top-b.top)[0];if(!overlap)break;end=overlap.top;}
      cuts.push(Math.max(start+1,end));}
    return {width,height,cuts};
  },
  finishPrint:()=>{document.body.classList.remove('printing');reading.hidden=mode!=='reading';source.hidden=mode!=='source';},
  snapshot:()=>({text,mode,reason,token,version,plainText,wordWrap,headings:plainText?[]:headings(text)})
};window.EditorAPI=api;

async function boot(){
  milk=await Editor.make().config(ctx=>{ctx.set(rootCtx,visual);ctx.set(defaultValueCtx,'');}).use(commonmark).use(gfm).use(history).use($remark('math',()=>remarkMath)).use(mathPlugins).use(syncPlugin).create();
  cm=new EditorView({parent:source,state:EditorState.create({doc:'',extensions:[lineNumbers(),highlightActiveLine(),drawSelection(),cmHistory(),cmLanguage.of(markdown()),syntaxHighlighting(defaultHighlightStyle),keymap.of([...defaultKeymap,...historyKeymap]),cmTheme.of([]),cmWrap.of(EditorView.lineWrapping),EditorView.updateListener.of(update=>{if(update.docChanged)changed(update.state.doc.toString());if(update.selectionSet){savedOffset=update.state.selection.main.head;savedSelection={from:update.state.selection.main.from,to:update.state.selection.main.to};stats();}})]})});
  document.querySelectorAll<HTMLElement>('[data-action]').forEach(button=>{button.onmousedown=e=>e.preventDefault();button.onclick=()=>void action(button.dataset.action!);});
  document.querySelectorAll<HTMLElement>('[data-table]').forEach(button=>{button.onmousedown=e=>e.preventDefault();button.onclick=()=>{const cmd=button.dataset.table!,view=milk.ctx.get(editorViewCtx);lastEdit=0;
    if(cmd==='row+')milk.action(callCommand(addRowAfterCommand.key));else if(cmd==='col+')milk.action(callCommand(addColAfterCommand.key));
    else if(cmd==='row-')deleteRow(view.state,view.dispatch);else if(cmd==='col-')deleteColumn(view.state,view.dispatch);else if(cmd==='delete')deleteTable(view.state,view.dispatch);
    else milk.action(callCommand(setAlignCommand.key,cmd as 'left'|'center'|'right'));view.focus();};});
  ['dialog-close','dialog-cancel'].forEach(id=>$(id).onclick=()=>$<HTMLDialogElement>('insert-dialog').close());
  const closeFind=()=>{$('find').hidden=true;api.focus();};
  $('find-close').onclick=closeFind;
  $('find-previous').onclick=()=>void findNext(true);$('find-next').onclick=()=>void findNext();$('find-all').onclick=findAll;
  $('replace-one').onclick=()=>void replaceFound();$('replace-all').onclick=()=>void replaceFound(true);
  $('query').oninput=scheduleSearch;$('match-case').onchange=refreshSearch;
  $('results-toggle').onclick=()=>{resultsCollapsed=!resultsCollapsed;updateResultsCollapsed();};
  $('results-clear').onclick=()=>{resultsListed=false;$('results-list').replaceChildren();$('results-count').textContent='结果已清空';$('results-empty').textContent='结果已清空，点击「全文查找」重新查找';$('results-empty').hidden=false;};
  $('query').onkeydown=e=>{if(e.key==='Enter'&&!e.isComposing){e.preventDefault();void findNext(e.shiftKey);}};
  $('replacement').onkeydown=e=>{if(e.key==='Enter'&&!e.isComposing){e.preventDefault();void replaceFound();}};
  const inEditor=(target:EventTarget|null)=>target instanceof Node&&(source.contains(target)||visual.contains(target));
  document.addEventListener('compositionstart',event=>{if(!inEditor(event.target))return;composing=true;pendingComposed=null;post('composition',{active:true});},true);
  document.addEventListener('compositionend',event=>{if(!inEditor(event.target))return;setTimeout(()=>{composing=false;post('composition',{active:false});const next=mode==='visual'?milk.ctx.get(serializerCtx)(milk.ctx.get(editorViewCtx).state.doc):cm.state.doc.toString();pendingComposed=null;changed(next);},0);},true);
  document.addEventListener('keydown',e=>{
    if($<HTMLDialogElement>('insert-dialog').open||e.isComposing)return;
    if(e.key==='Escape'&&!$('find').hidden){e.preventDefault();closeFind();return;}
    const k=e.key.toLowerCase();
    if((e.metaKey||e.ctrlKey)&&(k==='f'||k==='g')){e.preventDefault();e.stopImmediatePropagation();void action(k==='g'?(e.shiftKey?'findPrevious':'findNext'):e.shiftKey?'findAll':e.altKey?'replace':'find');return;}
    if(e.target instanceof HTMLInputElement||e.target instanceof HTMLTextAreaElement)return;
    if(e.metaKey||e.ctrlKey){if(['e','k','s','z'].includes(k)){e.preventDefault();e.stopImmediatePropagation();if(k==='e')void setMode(mode==='reading'?'visual':'reading');if(k==='k')void action('link');if(k==='s')post('save',{copy:e.shiftKey});if(k==='z')void restoreHistory(e.shiftKey);}}},true);
  reading.addEventListener('dblclick',e=>{if((e.target as HTMLElement).closest('a,button'))return;captureReadingSelection();void setMode('visual');});
  reading.addEventListener('click',e=>{const target=e.target as HTMLElement;const copy=target.closest('.copy-code');if(copy){const code=copy.closest('.code-preview')?.querySelector('code')?.textContent||'';post('copy',{text:code});if(!window.webkit)void navigator.clipboard?.writeText(code);copy.textContent='已复制';setTimeout(()=>copy.textContent='复制',1500);}});
  document.addEventListener('click',e=>{const anchor=(e.target as HTMLElement).closest('a');if(!anchor)return;e.preventDefault();if(mode!=='reading')return;const href=anchor.getAttribute('href')||'';if(href.startsWith('#')){try{document.getElementById(decodeURIComponent(href.slice(1)))?.scrollIntoView();}catch{report('章节链接格式不正确。');}}else if(safeTarget(href))post('openLink',{href});});
  visual.addEventListener('click',e=>{const target=(e.target as HTMLElement).closest<HTMLElement>('li[data-item-type="task"]');if(!target||e.clientX>target.getBoundingClientRect().left)return;const view=milk.ctx.get(editorViewCtx);let pos=view.posAtDOM(target,0);const resolved=view.state.doc.resolve(pos);if(resolved.parent.type.name==='list_item')pos=resolved.before();const node=view.state.doc.nodeAt(pos);if(node?.attrs.checked!==undefined)view.dispatch(view.state.tr.setNodeMarkup(pos,undefined,{...node.attrs,checked:!node.attrs.checked}));});
  visual.addEventListener('click',e=>{const anchor=(e.target as HTMLElement).closest('a');if(!anchor)return;const view=milk.ctx.get(editorViewCtx),pos=view.posAtDOM(anchor,0);view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(Math.min(pos+1,view.state.doc.content.size)))));});
  visual.addEventListener('dblclick',e=>{
    const target=e.target as HTMLElement,view=milk.ctx.get(editorViewCtx);const math=target.closest<HTMLElement>('.math-node'),image=target.closest('img'),pre=target.closest('pre');
    if(math){const pos=view.posAtDOM(math,0);let found=-1;view.state.doc.descendants((node,p)=>{if((node.type.name==='inline_math'||node.type.name==='block_math')&&Math.abs(p-pos)<2)found=p;});if(found<0)return;const node=view.state.doc.nodeAt(found)!;
      dialog('编辑公式',[{name:'value',label:'LaTeX 公式',type:'textarea',value:node.attrs.value}],values=>view.dispatch(view.state.tr.setNodeMarkup(found,undefined,{value:values.value})));}
    else if(image){const pos=view.posAtDOM(image,0);view.dispatch(view.state.tr.setSelection(NodeSelection.create(view.state.doc,pos)));
      const node=view.state.doc.nodeAt(pos)!;dialog('编辑图片',[{name:'src',label:'图片地址',value:node.attrs.src},{name:'alt',label:'替代文本',value:node.attrs.alt||''}],values=>{if(safeTarget(values.src)){view.dispatch(view.state.tr.setNodeMarkup(pos,undefined,{...node.attrs,src:values.src,alt:values.alt}));resolveImages(visual);}},()=>post('chooseImage'));}
    else if(pre){let pos=view.posAtDOM(pre,0);const resolved=view.state.doc.resolve(pos);if(resolved.parent.type.name==='code_block')pos=resolved.before();const node=view.state.doc.nodeAt(pos);if(node?.type.name!=='code_block')return;
      dialog('编辑代码块',[{name:'language',label:'语言',value:node.attrs.language},{name:'code',label:'内容',type:'textarea',value:node.textContent}],values=>{view.dispatch(view.state.tr.replaceWith(pos,pos+node.nodeSize,node.type.create({language:values.language},values.code?view.state.schema.text(values.code):undefined)));});}
  });
  document.addEventListener('paste',e=>{const files=e.clipboardData?.files;if(files?.length){e.preventDefault();e.stopImmediatePropagation();void importFiles(files);}},true);
  scroller.addEventListener('dragover',e=>{if(e.dataTransfer?.types.includes('Files'))e.preventDefault();});
  scroller.addEventListener('drop',e=>{if(e.dataTransfer?.files.length){e.preventDefault();e.stopPropagation();if(mode==='visual'){const view=milk.ctx.get(editorViewCtx),pos=view.posAtCoords({left:e.clientX,top:e.clientY});if(pos)view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(pos.pos))));}void importFiles(e.dataTransfer.files);}},true);
  let scrollFrame=0;const onScroll=()=>{cancelAnimationFrame(scrollFrame);scrollFrame=requestAnimationFrame(()=>{let line=0;
    if(mode==='reading'){const top=scroller.getBoundingClientRect().top;for(const el of reading.querySelectorAll<HTMLElement>('h1,h2,h3,h4,h5,h6')){if(el.getBoundingClientRect().top<=top+90)line=Number(el.dataset.line||0);}}
    else if(mode==='source'){const pos=cm.lineBlockAtHeight(cm.scrollDOM.scrollTop).from;line=cm.state.doc.lineAt(pos).number-1;}
    else{const top=scroller.getBoundingClientRect().top;const domHeads=[...visual.querySelectorAll<HTMLElement>('h1,h2,h3,h4,h5,h6')],hs=headings(text);domHeads.forEach((el,i)=>{if(el.getBoundingClientRect().top<=top+90)line=hs[i]?.line||0;});}
    post('activeHeading',{line});});};
  scroller.addEventListener('scroll',onScroll);cm.scrollDOM.addEventListener('scroll',onScroll);
  ready=true;post('ready');if(!window.webkit)await load({text:'# 一页文字\n\n阅读、思考，然后开始写作。\n',token:'browser',mode:'reading',theme:'light'});
}
boot().catch(error=>{report('编辑器加载失败：'+String(error));post('error',{message:String(error)});});
