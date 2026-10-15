function [dy, dx] = peak(correlation, product, rows, columns, subpixel)
%peak The shift of the largest correlation among the shifts rows x columns (the first in row-major order of equal ones)
%
%   With subpixel, refined as NoRMCorre does: the correlation is computed on
%   a grid of 1/20 pixel within a pixel of that peak, from the cross-power
%   spectrum (product), and its largest value taken (the first in row-major
%   order of equal ones), as Python's ophys_methods._peak.
    [height, width] = size(correlation);
    window = correlation(mod(rows, height) + 1, mod(columns, width) + 1);
    flat = reshape(window.', 1, []);   % row-major
    [~, best] = max(flat);
    best = best - 1;
    dy = rows(floor(best / numel(columns)) + 1);
    dx = columns(mod(best, numel(columns)) + 1);
    if ~subpixel
        return
    end
    upsample = 20;
    offsets = (-upsample:upsample) / upsample;
    down = exp(2i * pi * ((dy + offsets).' * frequencies(height)));
    across = exp(2i * pi * (frequencies(width).' * (dx + offsets)));
    values = real(down * product * across);
    flat = reshape(values.', 1, []);
    [~, best] = max(flat);
    best = best - 1;
    dy = dy + offsets(floor(best / numel(offsets)) + 1);
    dx = dx + offsets(mod(best, numel(offsets)) + 1);
end

function f = frequencies(n)
    f = [0:ceil(n / 2) - 1, -floor(n / 2):-1] / n;   % numpy.fft.fftfreq
end
