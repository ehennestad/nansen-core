function kernel = ringKernel(im, inner, outer)
%ringKernel The ring template of shape detection: a nucleus, a ring and the rest, blurred by a Gaussian of 1 px
%
%   A square of 2 * outer + 5 px: within inner of the centre the image's 5th
%   percentile, out to outer its 99th, and its 50th further out; as
%   Python's ophys_methods.ring_kernel.
    sigma = 1;
    size_ = 2 * outer + 2 * ceil(2 * sigma) + 1;
    centre = (size_ - 1) / 2;
    [columns, rows] = meshgrid(0:size_ - 1, 0:size_ - 1);
    distance = (rows - centre) .^ 2 + (columns - centre) .^ 2;
    nucleus = ophys.internal.percentileOf(im(:), 5);
    background = ophys.internal.percentileOf(im(:), 50);
    ring = ophys.internal.percentileOf(im(:), 99);
    kernel = background * ones(size_);
    kernel(distance <= outer ^ 2) = ring;
    kernel(distance <= inner ^ 2) = nucleus;
    kernel = ophys.internal.blur5(ophys.internal.blur5(kernel, 1, false), 2, false);
end
