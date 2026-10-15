function aligned = alignFrames(frames, shifts, weights, subpixel)
%alignFrames Frames moved back by their shifts (n x 2 x patches x patches)
%
%   By whole pixels when the shifts are rigid and whole, otherwise each
%   pixel by its shift, interpolated between the patch centres, and
%   bilinearly. weights holds the rows' and columns' ophys.internal.axisWeights.
    n = size(frames, 3);
    if size(shifts, 3) == 1 && ~subpixel
        aligned = ophys.internal.applyShifts(frames, shifts(:, :, 1, 1));
    elseif size(shifts, 3) == 1
        aligned = ophys.internal.warp(frames, reshape(shifts(:, 1, 1, 1), 1, 1, n), reshape(shifts(:, 2, 1, 1), 1, 1, n));
    else
        [height, width] = size(frames, 1:2);
        dy = zeros(height, width, n);
        dx = zeros(height, width, n);
        for t = 1:n
            dy(:, :, t) = ophys.internal.shiftField(reshape(shifts(t, 1, :, :), size(shifts, 3), []), weights{1}, weights{2});
            dx(:, :, t) = ophys.internal.shiftField(reshape(shifts(t, 2, :, :), size(shifts, 3), []), weights{1}, weights{2});
        end
        aligned = ophys.internal.warp(frames, dy, dx);
    end
end
