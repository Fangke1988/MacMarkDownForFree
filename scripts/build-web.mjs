import { build } from 'esbuild';
import { mkdir, copyFile } from 'node:fs/promises';
await mkdir('web/dist', {recursive:true});
await build({entryPoints:['web/src/app.ts'],bundle:true,outfile:'web/dist/app.js',format:'iife',target:['safari16'],minify:true,loader:{'.woff':'file','.woff2':'file','.ttf':'file'},assetNames:'fonts/[name]-[hash]',logLevel:'info'});
await copyFile('web/index.html','web/dist/index.html');
