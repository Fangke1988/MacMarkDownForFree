import {test,expect,Page} from '@playwright/test';

async function load(page:Page,text:string,plainText=true,mode:'reading'|'source'|'visual'='reading'){
  await page.goto('/');await page.waitForFunction(()=>window.EditorAPI?.snapshot().token==='browser');
  await page.evaluate(async payload=>window.EditorAPI.load(payload),{text,plainText,mode,wordWrap:true,token:'search-test',theme:'light'});
}
async function search(page:Page,query:string){
  await page.evaluate(()=>window.EditorAPI.action('find'));await page.locator('#query').fill(query);await page.locator('#find-all').click();
}

test('TXT stays literal through mode switches, Markdown actions and printing',async({page})=>{
  const text='# 原样文本\r\n**不是加粗** <script>alert(1)</script>\r\n';
  await load(page,text);
  await expect(page.locator('#source')).toBeVisible();await expect(page.locator('#format')).toBeHidden();
  for(const mode of ['visual','reading'] as const)await page.evaluate(mode=>window.EditorAPI.setMode(mode),mode);
  await page.evaluate(()=>window.EditorAPI.action('bold'));
  expect(await page.evaluate(()=>window.EditorAPI.snapshot())).toMatchObject({text,mode:'source',headings:[]});
  await search(page,'原样');
  await page.evaluate(()=>window.EditorAPI.preparePrint());await expect(page.locator('#find-results')).toBeHidden();
  await expect(page.locator('#reading pre')).toHaveText(text);await expect(page.locator('#reading h1')).toHaveCount(0);await expect(page.locator('#reading script')).toHaveCount(0);
  await page.evaluate(()=>window.EditorAPI.finishPrint());await expect(page.locator('#source')).toBeVisible();
});

test('whole-file results locate CRLF matches, collapse, clear and survive closing search',async({page})=>{
  const text='# 文档\r\n\r\n苹果 苹果\r\n末尾 苹果\r\n';
  await load(page,text,false);
  await search(page,'苹果');
  await expect(page.locator('#results-list li')).toHaveCount(3);
  await expect(page.locator('.result-position')).toHaveText(['3:1','3:4','4:4']);
  await page.locator('#results-list button').nth(2).click();
  await expect.poll(()=>page.evaluate(()=>window.getSelection()?.toString())).toBe('苹果');
  expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toBe(text);
  await expect(page.locator('#find-count')).toContainText('第 3 / 3');
  await page.locator('#find-next').click();await expect(page.locator('#find-count')).toContainText('第 1 / 3');
  await page.locator('#find-previous').click();await expect(page.locator('#find-count')).toContainText('第 3 / 3');
  const results=await page.locator('#find-results').boundingBox(),editor=await page.locator('#scroll').boundingBox();expect(results!.y).toBeGreaterThanOrEqual(editor!.y+editor!.height-1);
  await page.locator('#results-toggle').click();await expect(page.locator('#results-body')).toBeHidden();await expect(page.locator('#results-toggle')).toHaveAttribute('aria-expanded','false');
  await page.locator('#find-close').click();await expect(page.locator('#find-results')).toBeVisible();
  await page.locator('#results-toggle').click();await expect(page.locator('#results-list li')).toHaveCount(3);
  await page.locator('#results-clear').click();await expect(page.locator('#results-list li')).toHaveCount(0);await expect(page.locator('#results-count')).toHaveText('结果已清空');
  await page.evaluate(()=>window.EditorAPI.action('findAll'));await expect(page.locator('#results-list li')).toHaveCount(3);
});

test('literal queries, case sensitivity, replacement text and undo boundaries',async({page})=>{
  const original='苹果 苹果\nApple apple APPLE\n.* [x] .*\n';await load(page,original);
  await search(page,'.*');await expect(page.locator('#results-list li')).toHaveCount(2);
  await page.locator('#replacement').fill('$&\\n');await page.locator('#replace-all').click();
  expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toBe('苹果 苹果\nApple apple APPLE\n$&\\n [x] $&\\n\n');
  await expect(page.locator('#find-count')).toContainText('已替换 2 处');await expect(page.locator('#results-list li')).toHaveCount(0);
  await page.locator('.cm-content').click();await page.keyboard.press('ControlOrMeta+z');expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toBe(original);
  await page.locator('#query').fill('apple');await expect(page.locator('#results-list li')).toHaveCount(3);
  await page.locator('#match-case').check();await expect(page.locator('#results-list li')).toHaveCount(1);
  await page.locator('#replacement').fill('');await page.locator('#replace-one').click();
  expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toBe(original.replace('apple',''));
  await page.locator('#query').fill('不存在');await expect(page.locator('#replace-all')).toBeDisabled();await expect(page.locator('#results-empty')).toHaveText('没有匹配结果');
  await page.locator('#query').fill('');await expect(page.locator('#find-all')).toBeDisabled();expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toBe(original.replace('apple',''));
});

test('replace all is one undo step, preserves later typing and updates result positions',async({page})=>{
  await load(page,'苹果 苹果\n苹果');await search(page,'苹果');await page.locator('#replacement').fill('橘子水果');await page.locator('#replace-all').click();
  await page.locator('.cm-content').click();await page.keyboard.press('ControlOrMeta+End');await page.keyboard.insertText('新增');
  await page.keyboard.press('ControlOrMeta+z');expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toBe('橘子水果 橘子水果\n橘子水果');
  await page.keyboard.press('ControlOrMeta+z');expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toBe('苹果 苹果\n苹果');await expect(page.locator('#results-list li')).toHaveCount(3);
  await page.keyboard.press('ControlOrMeta+Shift+z');expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toBe('橘子水果 橘子水果\n橘子水果');
  await page.locator('#query').fill('橘子');await expect(page.locator('.result-position')).toHaveText(['1:1','1:6','2:1']);
});

test('word wrap changes layout without changing text, selection or history',async({page})=>{
  for(const plainText of [true,false]){
    const text='一段文字ABC'.repeat(90);await load(page,text,plainText,'source');
    await page.locator('.cm-content').click();await page.keyboard.press('ControlOrMeta+Home');await page.keyboard.insertText('新增');
    const selection=await page.evaluate(()=>window.getSelection()?.anchorOffset);
    const wrapped=await page.locator('.cm-line').first().boundingBox();
    await page.evaluate(()=>window.EditorAPI.setWordWrap(false));await expect(page.locator('.cm-content')).toHaveCSS('white-space','pre');
    const unwrapped=await page.locator('.cm-line').first().boundingBox();expect(unwrapped!.height).toBeLessThan(wrapped!.height);
    expect(await page.evaluate(()=>{const el=document.querySelector('.cm-scroller')!;return el.scrollWidth>el.clientWidth;})).toBe(true);
    expect(await page.evaluate(()=>window.getSelection()?.anchorOffset)).toBe(selection);
    await page.evaluate(()=>window.EditorAPI.setWordWrap(true));
    expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toBe('新增'+text);
    await page.keyboard.press('ControlOrMeta+z');expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toBe(text);
  }
});

test('IME in search input never alters the document or editor composition state',async({page})=>{
  const text='# 中文\n\n苹果\n';await load(page,text,false,'visual');await page.evaluate(()=>window.EditorAPI.action('find'));
  await page.locator('#query').dispatchEvent('compositionstart');await page.locator('#query').fill('苹果');await page.locator('#query').dispatchEvent('compositionend',{data:'苹果'});
  await page.locator('#find-all').click();await expect(page.locator('#results-list li')).toHaveCount(1);
  expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toBe(text);
  expect(await page.evaluate(()=>window.__events.filter((event:any)=>event.type==='change'||event.type==='composition'))).toEqual([]);
});

test('results reach document end and reload clears old results',async({page})=>{
  const text=Array.from({length:1200},(_,i)=>`第 ${i+1} 行 苹果`).join('\n');await load(page,text);await search(page,'苹果');
  await expect(page.locator('#results-list li')).toHaveCount(1200);await page.locator('#results-list button').last().click();
  await expect.poll(()=>page.evaluate(()=>window.getSelection()?.toString())).toBe('苹果');
  await expect(page.locator('.cm-line').last()).toContainText('1200');
  await expect.poll(async()=>{const row=await page.locator('.cm-line').last().boundingBox(),viewport=await page.locator('#scroll').boundingBox();return row!.y>=viewport!.y&&row!.y<viewport!.y+viewport!.height;}).toBe(true);
  await page.evaluate(()=>window.EditorAPI.load({text:'新文件',token:'new-file',mode:'reading',theme:'light',plainText:true}));
  await expect(page.locator('#find-results')).toBeHidden();await expect(page.locator('#results-list li')).toHaveCount(0);
});

test('text type conversion retains content and search results in dark narrow layout',async({page},info)=>{
  await load(page,'# 日志\n\n任务已完成\n再次完成任务\n',false,'visual');await search(page,'任务');
  await page.evaluate(()=>window.EditorAPI.setDocumentType(true));await expect(page.locator('#format')).toBeHidden();
  expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toBe('# 日志\n\n任务已完成\n再次完成任务\n');
  await page.evaluate(()=>window.EditorAPI.setTheme('dark'));await page.setViewportSize({width:560,height:590});
  await expect(page.locator('#replace-all')).toBeVisible();await expect(page.locator('#results-clear')).toBeVisible();
  expect(await page.evaluate(()=>document.body.scrollWidth<=window.innerWidth)).toBe(true);
  await page.screenshot({path:`test-results/${info.project.name}-txt-search.png`});
  await page.evaluate(()=>window.EditorAPI.setDocumentType(false));await page.evaluate(()=>window.EditorAPI.setMode('visual'));await expect(page.locator('#visual h1')).toHaveText('日志');
});

test('save as and search navigation shortcuts reach their distinct actions',async({page})=>{
  await load(page,'苹果 苹果');await page.locator('.cm-content').click();await page.keyboard.press('ControlOrMeta+Shift+s');
  expect(await page.evaluate(()=>window.__events.filter((event:any)=>event.type==='save').at(-1))).toMatchObject({type:'save',copy:true});
  await page.keyboard.press('ControlOrMeta+s');expect(await page.evaluate(()=>window.__events.filter((event:any)=>event.type==='save').at(-1))).toMatchObject({type:'save',copy:false});
  await page.keyboard.press('ControlOrMeta+f');await page.locator('#query').fill('苹果');await page.keyboard.press('ControlOrMeta+Shift+f');
  await expect(page.locator('#results-list li')).toHaveCount(2);
  await page.keyboard.press('ControlOrMeta+g');await expect(page.locator('#find-count')).toContainText('第 1 / 2');
  await page.keyboard.press('ControlOrMeta+Shift+g');await expect(page.locator('#find-count')).toContainText('第 2 / 2');
});
