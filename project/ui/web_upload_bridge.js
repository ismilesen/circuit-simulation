// res://ui/web_upload_bridge.js
//
// Pushes the full picker selection to Godot as one batch item so the GDScript
// side can validate "at most one xchem + at most one spice per upload".
(() => {
  if (!window.godotUploadQueue) window.godotUploadQueue = [];

  const encodeToBase64 = (bytes) => {
    const chunkSize = 0x8000;
    let binary = "";
    for (let i = 0; i < bytes.length; i += chunkSize) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunkSize));
    }
    return btoa(binary);
  };

  window.godotUploadOpenPicker = function () {
    const input = document.createElement("input");
    input.type = "file";
    // Allow multi-select so the user can pick one xchem and one spice at once.
    // Godot enforces that at most one of each kind is accepted per batch.
    input.multiple = true;
    input.accept = [
      ".sch", ".sym",
      ".spice", ".cir", ".net", ".txt",
      ".zip", ".cvw.zip"
    ].join(",");

    input.onchange = async (e) => {
      const files = Array.from(e.target.files || []);
      if (files.length === 0) return;

      const batch = [];
      for (const file of files) {
        try {
          const buf = await file.arrayBuffer();
          const bytes = new Uint8Array(buf);
          const base64 = encodeToBase64(bytes);
          batch.push({
            name: file.name,
            size: file.size,
            type: file.type || "",
            base64: base64,
            error: ""
          });
        } catch (err) {
          batch.push({
            name: (file && file.name) || "unknown",
            size: (file && file.size) || 0,
            type: (file && file.type) || "",
            base64: "",
            error: String(err)
          });
        }
      }

      window.godotUploadQueue.push({
        type: "batch",
        files: batch
      });
    };

    input.click();
  };
})();
