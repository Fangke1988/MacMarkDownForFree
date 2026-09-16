import {test,expect,Page} from '@playwright/test';
async function load(page:Page,text:string,mode='reading'){
  await page.goto('/');await page.waitForFunction(()=>window.EditorAPI?.snapshot().token==='browser');
  await page.evaluate(async ({text,mode})=>window.EditorAPI.load({text,mode:mode as any,token:'test',theme:'light'}),{text,mode});
}
const fixture='# 中文文档\n\n一段 **加粗文字** 和 [链接](https://example.com)。\n\n## 表格\n\n| 名称 | 数量 |\n| :--- | ---: |\n| 图片 | 2 |\n\n## 公式\n\n行内公式 $x^2$。\n\n$$\nE=mc^2\n$$\n\n## 图表\n\n```mermaid\nflowchart LR\n  A[开始] --> B[完成]\n```\n\n```javascript\nconst message = "你好";\n```\n';
test('mode changes retain exact Markdown and render technical content',async({page})=>{
  await load(page,fixture);await expect(page.locator('.diagram svg')).toBeVisible();await expect(page.locator('#reading .katex')).toHaveCount(2);
  for(const mode of ['visual','source','reading']){await page.evaluate(async mode=>window.EditorAPI.setMode(mode as any),mode);expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toBe(fixture);expect(await page.evaluate(()=>window.EditorAPI.snapshot().mode)).toBe(mode);}
  expect(await page.evaluate(()=>window.__events.filter((e:any)=>e.type==='change'))).toEqual([]);
});
test('visual editing and undo survive source switch',async({page})=>{
  await load(page,'# 标题\n\n正文\n','visual');await expect(page.locator('#visual')).toBeVisible();
  await page.locator('.ProseMirror p').click();await page.keyboard.press('End');await page.keyboard.insertText('新增文字');
  expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toContain('新增文字');
  await page.evaluate(()=>window.EditorAPI.setMode('source'));await page.evaluate(()=>window.EditorAPI.action('undo'));
  expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toBe('# 标题\n\n正文\n');
  await page.evaluate(()=>window.EditorAPI.action('redo'));expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toContain('新增文字');
});
test('table creation and editing uses real Markdown',async({page})=>{
  await load(page,'# 表格测试\n\n','reading');await page.evaluate(()=>window.EditorAPI.action('table'));await page.locator('[name=rows]').fill('2');await page.locator('[name=cols]').fill('2');await page.getByRole('button',{name:'插入',exact:true}).click();
  await expect(page.locator('#visual table')).toBeVisible();await page.locator('#visual td').first().click();await page.keyboard.insertText('测试');
  await page.getByRole('button',{name:'加行',exact:true}).click();expect(await page.locator('#visual tr').count()).toBe(4);
  await page.evaluate(()=>window.EditorAPI.setMode('reading'));await expect(page.locator('#reading table')).toContainText('测试');
});
test('unsupported syntax stays intact and routes to source',async({page})=>{
  for(const raw of ['---\ntitle: 测试\n---\n\n# 标题\n','<div onclick="alert(1)">内容</div>\n','[[笔记]]\n\n[^1]: 脚注\n']){
    await load(page,raw,'visual');expect(await page.evaluate(()=>window.EditorAPI.snapshot().mode)).toBe('source');expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toBe(raw);await expect(page.locator('#notice')).toBeVisible();
  }
});
test('find replace and dark mode',async({page})=>{
  await load(page,'# 计划\n\n苹果 苹果\n','source');await page.evaluate(()=>window.EditorAPI.action('find'));await page.locator('#query').fill('苹果');await page.locator('#replacement').fill('橘子');await page.locator('#replace-all').click();expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toBe('# 计划\n\n橘子 橘子\n');
  await page.evaluate(()=>window.EditorAPI.setTheme('dark'));await expect(page.locator('html')).toHaveAttribute('data-theme','dark');
});
test('link insertion and malicious HTML stays inert',async({page})=>{
  await load(page,'# 链接\n\n','reading');await page.evaluate(()=>window.EditorAPI.action('link'));await page.locator('[name=label]').fill('官方文档');await page.locator('[name=url]').fill('https://example.com/docs');await page.getByRole('button',{name:'插入',exact:true}).click();await page.evaluate(()=>window.EditorAPI.setMode('reading'));await expect(page.locator('#reading a')).toHaveAttribute('href','https://example.com/docs');
  await load(page,'<script>window.hacked=true</script>\n\n[危险](javascript:alert(1))\n');expect(await page.evaluate(()=>(window as any).hacked)).toBeUndefined();expect(await page.locator('#reading script').count()).toBe(0);
});
test('composition does not publish intermediate input',async({page})=>{
  await load(page,'正文\n','source');await page.locator('.cm-content').click();await page.evaluate(()=>document.querySelector('.cm-content')!.dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true})));
  await page.keyboard.insertText('中文');expect(await page.evaluate(()=>window.__events.filter((e:any)=>e.type==='change').length)).toBe(0);
  await page.evaluate(()=>document.querySelector('.cm-content')!.dispatchEvent(new CompositionEvent('compositionend',{bubbles:true,data:'中文'})));
  await expect.poll(()=>page.evaluate(()=>window.EditorAPI.snapshot().text)).toContain('中文');
});
test('screenshot reading and editing themes',async({page},info)=>{
  await load(page,fixture);await expect(page.locator('.diagram svg')).toBeAttached();await page.screenshot({path:`delivery/${info.project.name}-reading-light.png`});
  await page.evaluate(()=>window.EditorAPI.setTheme('dark'));await page.screenshot({path:`delivery/${info.project.name}-reading-dark.png`});
  await page.evaluate(()=>window.EditorAPI.setMode('visual'));await page.screenshot({path:`delivery/${info.project.name}-editing-dark.png`});
});
test('existing links keep their label when edited',async({page})=>{
  await load(page,'# 文档\n\n前缀 [原始名称](https://example.com) 后缀\n','visual');
  await page.locator('#visual a').click();await page.evaluate(()=>window.EditorAPI.action('link'));
  await expect(page.locator('[name=label]')).toHaveValue('原始名称');await page.locator('[name=url]').fill('https://example.org');await page.getByRole('button',{name:'插入',exact:true}).click();
  await page.evaluate(()=>window.EditorAPI.setMode('reading'));await expect(page.locator('#reading a')).toHaveText('原始名称');await expect(page.locator('#reading a')).toHaveAttribute('href','https://example.org');
});
test('image attributes survive visual changes and dialog editing',async({page})=>{
  await load(page,'# 图片\n\n![旧名称](assets/test.png)\n\n正文\n','visual');
  await page.locator('#visual img[alt=旧名称]').dblclick();await page.locator('[name=alt]').fill('新名称');await page.getByRole('button',{name:'插入',exact:true}).click();
  expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toContain('![新名称](assets/test.png)');
  await page.locator('#visual p').last().click();await page.keyboard.insertText('编辑');expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).not.toContain('mdasset:');
});
test('math dialog gives live preview and saves formula',async({page})=>{
  await load(page,'# 公式\n\n','visual');await page.evaluate(()=>window.EditorAPI.action('math'));await page.locator('[name=value]').fill('x^2 + y^2');await expect(page.locator('.dialog-preview .katex')).toBeVisible();await page.getByRole('button',{name:'插入',exact:true}).click();await expect(page.locator('#visual .math-node')).toBeVisible();
  await page.locator('#visual .math-node').dblclick();await page.locator('[name=value]').fill('a+b');await page.getByRole('button',{name:'插入',exact:true}).click();expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toContain('a+b');
});
test('task lists render as checkboxes and remain visually editable',async({page})=>{
  await load(page,'# 任务\n\n- [ ] 待完成\n- [x] 已完成\n');await expect(page.locator('#reading input[type=checkbox]')).toHaveCount(2);
  await page.evaluate(()=>window.EditorAPI.setMode('visual'));expect(await page.evaluate(()=>window.EditorAPI.snapshot().mode)).toBe('visual');
  const item=page.locator('#visual li').first();const box=(await item.boundingBox())!;await page.mouse.click(box.x-14,box.y+12);expect(await page.evaluate(()=>window.EditorAPI.snapshot().text)).toContain('[x] 待完成');
});
