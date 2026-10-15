function offsets = diskOffsets(radius)
%diskOffsets The [dy, dx] offsets of a disk, dy^2 + dx^2 <= radius^2, in the order Python lists them
    [dx, dy] = meshgrid(-radius:radius, -radius:radius);
    dy = dy.';
    dx = dx.';
    keep = dy(:) .^ 2 + dx(:) .^ 2 <= radius ^ 2;
    offsets = [dy(keep), dx(keep)];
end
