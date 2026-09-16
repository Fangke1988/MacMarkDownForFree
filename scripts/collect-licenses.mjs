import {readFile,readdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
const lock=JSON.parse(await readFile('package-lock.json','utf8'));
const sections=[];
for(const [dir,meta] of Object.entries(lock.packages)){
  if(!dir||meta.dev)continue;
  try{
    const pkg=JSON.parse(await readFile(path.join(dir,'package.json'),'utf8'));
    const files=(await readdir(dir)).filter(name=>/^(license|licence|copying)(\.|$)/i.test(name));
    const licenses=await Promise.all(files.map(name=>readFile(path.join(dir,name),'utf8')));
    sections.push(`${pkg.name} ${pkg.version}\nLicense: ${typeof pkg.license==='string'?pkg.license:JSON.stringify(pkg.license)}\n${licenses.join('\n')}`);
  }catch{}
}
await writeFile('THIRD-PARTY-NOTICES.txt',sections.join('\n\n'+'='.repeat(72)+'\n\n'));
