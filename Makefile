out.jpg: raytrace
	./raytrace

raytrace: raytrace.zig jpeg_writer.zig
	zig build-exe raytrace.zig --release-fast

time: raytrace
	time ./raytrace

clean:
	rm -rf zig-cache raytrace out.jpg

.PHONY: clean all
