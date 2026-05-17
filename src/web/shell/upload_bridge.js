// upload_bridge.js
// Robust upload queue for Godot Web exports.
// Godot will poll window.godotUploadQueue via JavaScriptBridge.eval and pop one item at a time.
//
// Queue items look like:
// { name, size, mime, ext, base64 }

(function () {
    if (!Array.isArray(window.godotUploadQueue)) window.godotUploadQueue = [];
  
    function getExt(name) {
      const i = name.lastIndexOf(".");
      return i >= 0 ? name.slice(i + 1).toLowerCase() : "";
    }
  
    // Convert ArrayBuffer -> base64 without blowing the call stack.
    function arrayBufferToBase64(buffer) {
      const bytes = new Uint8Array(buffer);
      const chunkSize = 0x8000; // 32 KB chunks, safe for apply/stack limits
      let binary = "";
      for (let i = 0; i < bytes.length; i += chunkSize) {
        const chunk = bytes.subarray(i, i + chunkSize);
        binary += String.fromCharCode.apply(null, chunk);
      }
      return btoa(binary);
    }
  
    async function enqueueFile(file) {
      const buf = await file.arrayBuffer();
      const base64 = arrayBufferToBase64(buf);
      window.godotUploadQueue.push({
        name: file.name,
        size: file.size,
        mime: file.type || "",
        ext: getExt(file.name),
        base64: base64
      });
    }
  
    window.godotUploadOpenPicker = function () {
      const input = document.createElement("input");
      input.type = "file";
      input.multiple = true;
      input.accept = ".sch,.spice,.cir,.net,.txt";
  
      input.addEventListener("change", async () => {
        const files = input.files ? Array.from(input.files) : [];
        for (const f of files) {
          try {
            await enqueueFile(f);
          } catch (e) {
            // Push an error marker rather than failing silently.
            window.godotUploadQueue.push({
              name: f && f.name ? f.name : "unknown",
              size: 0,
              mime: "",
              ext: "",
              base64: "",
              error: String(e)
            });
          }
        }
      });
  
      // Must be in DOM for some browsers
      input.style.position = "fixed";
      input.style.left = "-9999px";
      document.body.appendChild(input);
      input.click();
  
      // Cleanup after selection
      setTimeout(() => {
        try { document.body.removeChild(input); } catch (_) {}
      }, 1000);
    };
  })();
  