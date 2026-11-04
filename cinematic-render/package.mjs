import fs from 'node:fs/promises';
import path from 'node:path';
import sharp from 'sharp';
import {execFileSync} from 'node:child_process';
const source=path.resolve('rendered'),dest=path.resolve('packaged'),sequence=path.resolve('sequence');
const files=(await fs.readdir(source)).filter(n=>/^\d{4}\.png$/.test(n)).sort();
if(files.length!==125||files.some((n,i)=>n!==`${String(i).padStart(4,'0')}.png`))throw Error('Incomplete 125-frame rotation');
await fs.mkdir(path.join(dest,'frames'),{recursive:true});await fs.mkdir(sequence,{recursive:true});
for(const [i,n] of files.entries()){
 const image=sharp(path.join(source,n));
 await image.clone().webp({quality:84,alphaQuality:80,effort:5}).toFile(path.join(dest,'frames',`${String(i).padStart(3,'0')}.webp`));
 await image.flatten({background:'#efe9df'}).png().toFile(path.join(sequence,n));
}
await sharp(path.join(source,files[0])).flatten({background:'#efe9df'}).webp({quality:90,effort:5}).toFile(path.join(dest,'poster.webp'));
const input=['-y','-loglevel','error','-framerate','25','-i',path.join(sequence,'%04d.png'),'-frames:v','125','-pix_fmt','yuv420p','-an'];
execFileSync('ffmpeg',[...input,'-c:v','libx264','-crf','19','-preset','slow','-profile:v','high','-movflags','+faststart',path.join(dest,'spin.mp4')],{stdio:'inherit'});
execFileSync('ffmpeg',[...input,'-c:v','libvpx-vp9','-b:v','0','-crf','26','-deadline','good','-row-mt','1',path.join(dest,'spin.webm')],{stdio:'inherit'});
for(const ext of ['mp4','webm']){
 const p=JSON.parse(execFileSync('ffprobe',['-v','error','-select_streams','v:0','-show_entries','stream=width,height,nb_frames,avg_frame_rate:format=duration','-of','json',path.join(dest,`spin.${ext}`)],{encoding:'utf8'}));
 if(p.streams[0].width!==720||p.streams[0].height!==720||p.streams[0].avg_frame_rate!=='25/1'||Math.abs(Number(p.format.duration)-5)>0.05)throw Error(`Invalid video: ${ext}`);
 execFileSync('ffmpeg',['-v','error','-i',path.join(dest,`spin.${ext}`),'-f','null','-'],{stdio:'inherit'});
}
console.log('Verified complete native 360 degree turntable, 125 frames, 25fps, 5 seconds, 720x720, both codecs decode.');
