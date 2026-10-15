function out = gaussianCircular(stack, sigma)
%gaussianCircular Each frame smoothed by a Gaussian of sigma pixels, wrapping around the edges (by FFT)
    [height, width, ~] = size(stack);
    fy = [0:ceil(height / 2) - 1, -floor(height / 2):-1]' / height;
    fx = [0:ceil(width / 2) - 1, -floor(width / 2):-1] / width;
    filter = exp(-2 * pi ^ 2 * sigma ^ 2 * fy .^ 2) .* exp(-2 * pi ^ 2 * sigma ^ 2 * fx .^ 2);
    out = real(ifft2(fft2(stack) .* filter));
end
