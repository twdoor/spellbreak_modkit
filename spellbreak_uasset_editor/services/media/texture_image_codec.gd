class_name TextureImageCodec extends RefCounted

## Runtime image conversion; no external image application is needed.
static func to_png(source: String, destination: String) -> OperationResult:
	var img := Image.load_from_file(source)
	if img == null or img.is_empty():
		return OperationResult.failed("Could not decode texture image: " + source)
	# HDR radiance is linear; PNG previews are display-referred. Keep this
	# conversion explicit rather than silently treating linear floats as sRGB.
	if source.get_extension().to_lower() == "hdr":
		var display := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
		for y in img.get_height():
			for x in img.get_width():
				display.set_pixel(x, y, img.get_pixel(x, y).linear_to_srgb())
		img = display
	img.convert(Image.FORMAT_RGBA8)
	var error := img.save_png(destination)
	if error != OK:
		return OperationResult.failed("Could not save texture PNG (error %d)" % error)
	return OperationResult.succeeded("", destination)


static func to_tga(source: String, destination: String) -> OperationResult:
	var img := Image.load_from_file(source)
	if img == null or img.is_empty():
		return OperationResult.failed("Could not decode texture PNG: " + source)
	var bytes := encode_tga(img)
	if bytes.is_empty():
		return OperationResult.failed("Texture dimensions exceed the TGA limit (65535)")
	var error := FileUtils.write_bytes_atomic(destination, bytes)
	if error != OK:
		return OperationResult.failed("Could not save texture TGA (error %d)" % error)
	return OperationResult.succeeded("", destination)


static func encode_tga(image: Image) -> PackedByteArray:
	if image.is_empty() or image.get_width() > 65535 or image.get_height() > 65535:
		return PackedByteArray()
	var img := image.duplicate() as Image
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RGBA8)
	var pixels := img.get_data()
	# True-color, uncompressed BGRA, top-left origin, eight alpha bits.
	var header := PackedByteArray()
	header.resize(18)
	header[2] = 2
	header.encode_u16(12, img.get_width())
	header.encode_u16(14, img.get_height())
	header[16] = 32
	header[17] = 0x28
	for i in range(0, pixels.size(), 4):
		var red := pixels[i]
		pixels[i] = pixels[i + 2]
		pixels[i + 2] = red
	header.append_array(pixels)
	return header
