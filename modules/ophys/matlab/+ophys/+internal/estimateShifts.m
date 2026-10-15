function shifts = estimateShifts(frames, referenceFft, maxShift, subpixel, tapered)
%estimateShifts [rows, columns] each frame of a height x width x n stack is displaced from the reference: n x 2
%
%   referenceFft is the conjugate of the reference's 2-D FFT times the
%   smoothing. The peak of the phase correlation is looked for within
%   maxShift (and less than half the frame); of equal peaks, the one of
%   smallest row shift, then column shift, wins, as in Python. With
%   subpixel, the peak is refined (see ophys.internal.peak). With tapered,
%   the frames are taken less their mean and weighted by the taper, as the
%   reference must have been.
    if nargin < 4
        subpixel = false;
    end
    if nargin < 5
        tapered = false;
    end
    [height, width, n] = size(frames);
    if tapered
        frames = ophys.internal.tapered(frames);
    end
    [correlation, product] = ophys.internal.correlation(frames, referenceFft);
    rows = ophys.internal.shiftRange(0, maxShift, maxShift, floor((height - 1) / 2));
    columns = ophys.internal.shiftRange(0, maxShift, maxShift, floor((width - 1) / 2));
    shifts = zeros(n, 2);
    for t = 1:n
        [shifts(t, 1), shifts(t, 2)] = ophys.internal.peak(correlation(:, :, t), product(:, :, t), rows, columns, subpixel);
    end
end
