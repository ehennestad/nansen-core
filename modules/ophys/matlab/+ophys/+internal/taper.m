function weights = taper(height, width)
%taper A patch's weights before its FFT, so its edges do not count: a Hann window (sin^2) along each axis
    weights = (sin(pi * ((0:height - 1)' + 0.5) / height) .^ 2) * (sin(pi * ((0:width - 1) + 0.5) / width) .^ 2);
end
