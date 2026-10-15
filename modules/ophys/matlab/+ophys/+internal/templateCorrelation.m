function score = templateCorrelation(im, kernel)
%templateCorrelation The Pearson correlation of a template with the window around each pixel (the image 0 outside); NaN where the window is uniform
    size_ = size(kernel, 1);
    half = (size_ - 1) / 2;
    [height, width] = size(im);
    padded = zeros(height + 2 * half, width + 2 * half);
    padded(half + 1:half + height, half + 1:half + width) = im;
    centred = kernel - mean(kernel, "all");
    total = zeros(height, width);
    squares = zeros(height, width);
    product = zeros(height, width);
    for dy = 1:size_
        for dx = 1:size_
            window = padded(dy:dy + height - 1, dx:dx + width - 1);
            total = total + window;
            squares = squares + window .* window;
            product = product + centred(dy, dx) * window;
        end
    end
    spread = squares - total .* total / (size_ * size_);
    score = product ./ sqrt(spread * sum(centred .* centred, "all"));
    score(spread <= 1e-12) = NaN;
end
