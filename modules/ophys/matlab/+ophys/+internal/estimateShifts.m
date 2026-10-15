function shifts = estimateShifts(frames, referenceFft, maxShift)
%estimateShifts [rows, columns] each frame of a height x width x n stack is displaced from the reference
%
%   referenceFft is the conjugate of the reference's 2-D FFT times the
%   smoothing. The peak of the phase correlation is looked for within
%   maxShift (and less than half the frame); of equal peaks, the one of
%   smallest row shift, then column shift, wins, as in Python.
    [height, width, ~] = size(frames);
    product = fft2(double(frames)) .* referenceFft;
    product = product ./ max(abs(product), 1e-12);
    correlation = real(ifft2(product));
    rows = -min(maxShift, floor((height - 1) / 2)):min(maxShift, floor((height - 1) / 2));
    columns = -min(maxShift, floor((width - 1) / 2)):min(maxShift, floor((width - 1) / 2));
    window = correlation(mod(rows, height) + 1, mod(columns, width) + 1, :);
    % row-major order, as numpy flattens: the column shift varies fastest
    flat = reshape(permute(window, [2, 1, 3]), numel(rows) * numel(columns), []);
    [~, best] = max(flat, [], 1);
    best = best(:) - 1;
    shifts = [reshape(rows(floor(best / numel(columns)) + 1), [], 1), reshape(columns(mod(best, numel(columns)) + 1), [], 1)];
end
