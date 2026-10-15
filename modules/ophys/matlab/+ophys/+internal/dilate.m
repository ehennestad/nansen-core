function out = dilate(mask, distance)
%dilate Pixels within square (Chebyshev) distance of the mask
    out = mask;
    for axis = 1:2
        grown = out;
        for step = 1:min(distance, size(out, axis) - 1)
            if axis == 1
                grown(step + 1:end, :) = grown(step + 1:end, :) | out(1:end - step, :);
                grown(1:end - step, :) = grown(1:end - step, :) | out(step + 1:end, :);
            else
                grown(:, step + 1:end) = grown(:, step + 1:end) | out(:, 1:end - step);
                grown(:, 1:end - step) = grown(:, 1:end - step) | out(:, step + 1:end);
            end
        end
        out = grown;
    end
end
