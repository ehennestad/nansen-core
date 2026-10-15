function out = dilateBy(mask, offsets)
%dilateBy Dilation with the given offsets
    out = false(size(mask));
    for i = 1:size(offsets, 1)
        out = out | ophys.internal.shiftedMask(mask, offsets(i, 1), offsets(i, 2), false);
    end
end
