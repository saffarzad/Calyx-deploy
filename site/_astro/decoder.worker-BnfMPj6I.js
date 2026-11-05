(function(){"use strict";self.onmessage=async t=>{const{i:e,blob:a}=t.data;try{const s=await createImageBitmap(a);self.postMessage({i:e,bmp:s},[s])}catch{self.postMessage({i:e,bmp:null})}}})();
