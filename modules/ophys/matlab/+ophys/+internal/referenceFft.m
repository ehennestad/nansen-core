function result = referenceFft(reference, tapered)
%referenceFft The conjugate FFT of a reference image (tapered, less its mean, when asked), times the smoothing
    if tapered
        reference = ophys.internal.tapered(reference);
    end
    result = conj(fft2(double(reference))) .* ophys.internal.smoothing(size(reference, 1), size(reference, 2));
end
