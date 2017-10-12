view: out.png
	feh out.png

raytrace: main.zig
	zig build

out.ppm: raytrace objects.list
	./raytrace objects.list > out.ppm

out.png: out.ppm
	convert out.ppm out.png

clean:
	rm -f raytrace out.ppm out.png
	rm -rf zig-cache

.PHONY: view clean
