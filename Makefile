out.png: out.ppm
	convert out.ppm out.png

out.ppm: raytrace
	./raytrace > out.ppm

raytrace: raytrace.zig
	zig build-exe raytrace.zig --release-fast

time: raytrace
	time ./raytrace > /dev/null

clean:
	rm -rf zig-cache raytrace out.ppm out.png

.PHONY: clean all
