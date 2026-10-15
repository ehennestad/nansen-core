function [correlation, product] = correlation(frames, referenceFft)
%correlation The (whitened, smoothed) phase correlation of each frame of a stack with the reference, and the cross-power spectrum it is the inverse FFT of
    product = fft2(double(frames)) .* referenceFft;
    product = product ./ max(abs(product), 1e-12);
    correlation = real(ifft2(product));
end
