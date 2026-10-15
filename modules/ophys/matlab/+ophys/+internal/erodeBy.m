function out = erodeBy(mask, offsets)
%erodeBy Erosion that treats the outside of the image as foreground, as imerode does
    out = true(size(mask));
    for i = 1:size(offsets, 1)
        out = out & ophys.internal.shiftedMask(mask, offsets(i, 1), offsets(i, 2), true);
    end
end
