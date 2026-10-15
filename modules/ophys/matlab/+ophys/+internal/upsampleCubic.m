function out = upsampleCubic(image, factor)
%upsampleCubic An image upsampled factor times by bicubic interpolation, as imresize does it
%
%   Keys' kernel (a = -0.5), output pixel j (from 0) at (j + 0.5) / factor
%   - 0.5 of the input, the edges mirrored (half-sample symmetric), the
%   weights of the four nearest pixels normalised to their sum; down the
%   rows, then along them. Without the Image Processing Toolbox; as
%   Python's ophys_methods.upsample_cubic, step for step.
    out = alongRows(double(image), factor);
    out = alongRows(out.', factor).';
end

function out = alongRows(values, factor)
    % Upsampled down the rows (the first dimension) of a matrix
    n = size(values, 1);
    out = zeros(n * factor, size(values, 2));
    mirror = [0:n - 1, n - 1:-1:0];   % half-sample symmetric, as imresize
    for j = 0:n * factor - 1
        x = (j + 0.5) / factor - 0.5;
        left = floor(x) - 1;
        weights = zeros(1, 4);
        for k = 0:3
            s = abs(x - (left + k));
            s2 = s * s;
            s3 = s2 * s;
            if s <= 1
                weights(k + 1) = 1.5 * s3 - 2.5 * s2 + 1;
            elseif s <= 2
                weights(k + 1) = -0.5 * s3 + 2.5 * s2 - 4 * s + 2;
            end
        end
        total = weights(1) + weights(2) + weights(3) + weights(4);
        rows = mirror(mod(left + (0:3), 2 * n) + 1) + 1;
        out(j + 1, :) = weights(1) / total * values(rows(1), :) + weights(2) / total * values(rows(2), :) ...
            + weights(3) / total * values(rows(3), :) + weights(4) / total * values(rows(4), :);
    end
end
