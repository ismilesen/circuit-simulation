// res://ui/web_upload_bridge.js
//
// Lightweight/legacy upload bridge kept beside the UI scene for manual web
// harnesses. The exported app should prefer project/web/upload_bridge.js, which
// batches picker and drag/drop payloads; both bridges fill godotUploadQueue with
// base64 file entries consumed by upload_panel.gd.
(() => {
  if (!window.godotUploadQueue) window.godotUploadQueue = [];

  window.godotUploadOpenPicker = function () {
	// Browser File objects cannot be passed directly into Godot, so the bridge
	// serializes each selected file to base64 and lets GDScript stage the bytes.
	const input = document.createElement("input");
	input.type = "file";
	input.multiple = true;

	input.onchange = async (e) => {
	  const files = Array.from(e.target.files || []);
	  for (const file of files) {
		try {
		  const buf = await file.arrayBuffer();
		  const bytes = new Uint8Array(buf);

		  // Convert to base64 in chunks to avoid call stack / memory spikes.
		  const chunkSize = 0x8000;
		  let binary = "";
		  for (let i = 0; i < bytes.length; i += chunkSize) {
			binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunkSize));
		  }
		  const base64 = btoa(binary);

		  window.godotUploadQueue.push({
			name: file.name,
			size: file.size,
			type: file.type || "",
			base64,
			error: ""
		  });
		} catch (err) {
		  window.godotUploadQueue.push({
			name: file?.name || "unknown",
			size: file?.size || 0,
			type: file?.type || "",
			base64: "",
			error: String(err)
		  });
		}
	  }
	};

	input.click();
  };
})();
