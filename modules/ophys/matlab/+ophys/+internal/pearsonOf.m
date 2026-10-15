function value = pearsonOf(a, b)
%pearsonOf The Pearson correlation of two arrays of the same size, element by element; NaN when either is constant
    a = double(a) - mean(double(a), "all");
    b = double(b) - mean(double(b), "all");
    scale = sqrt(sum(a .* a, "all") * sum(b .* b, "all"));
    if scale > 0
        value = sum(a .* b, "all") / scale;
    else
        value = NaN;
    end
end
