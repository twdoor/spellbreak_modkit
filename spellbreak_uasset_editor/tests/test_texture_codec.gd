extends SceneTree

var failures: Array[String] = []

func _init() -> void:
	var root := OS.get_temp_dir().path_join("sb-codec-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root)
	var pixels := PackedByteArray([255, 0, 0, 255, 0, 255, 0, 0, 0, 0, 255, 127, 71, 129, 203, 19])
	var img := Image.create_from_data(2, 2, false, Image.FORMAT_RGBA8, pixels)
	var source := root.path_join("source.png")
	img.save_png(source)
	var tga := root.path_join("converted.tga")
	check(TextureImageCodec.to_tga(source, tga).ok, "Encode TGA")
	var decoded := Image.load_from_file(tga)
	check(decoded != null and decoded.get_data() == pixels, "Preserve orientation, RGB and alpha exactly")
	var png := root.path_join("roundtrip.png")
	check(TextureImageCodec.to_png(tga, png).ok, "Decode TGA to PNG")
	check(Image.load_from_file(png).get_data() == pixels, "Lossless PNG/TGA roundtrip")
	# Radiance RGBE: two linear gray pixels (0.5 and 1.0).
	var hdr := "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 2\n".to_utf8_buffer()
	hdr.append_array(PackedByteArray([128, 128, 128, 128, 128, 128, 128, 129]))
	var hdr_path := root.path_join("linear.hdr")
	FileUtils.write_bytes_atomic(hdr_path, hdr)
	check(TextureImageCodec.to_png(hdr_path, png).ok, "HDR conversion")
	var hdr_image := Image.load_from_file(png)
	check(hdr_image.get_pixel(0, 0).r > 0.70 and hdr_image.get_pixel(0, 0).r < 0.76,
		"HDR linear gray is converted to display sRGB")
	FileUtils.remove_dir_recursive(root)
	for failure in failures:
		printerr("FAIL: " + failure)
	if failures.is_empty():
		print("PASS: texture image codecs")
	quit(0 if failures.is_empty() else 1)

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
