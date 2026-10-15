function filter = smoothing(height, width)
%smoothing A Gaussian of 1.15 pixels in the frequency domain, as suite2p smooths the phase correlation
    sigma = 1.15;
    fy = [0:ceil(height / 2) - 1, -floor(height / 2):-1]' / height;   % numpy.fft.fftfreq
    fx = [0:ceil(width / 2) - 1, -floor(width / 2):-1] / width;
    filter = exp(-2 * pi ^ 2 * sigma ^ 2 * (fy .^ 2 + fx .^ 2));
end
