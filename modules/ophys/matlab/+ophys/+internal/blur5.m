function out = blur5(values, dimension, circular)
%blur5 A Gaussian blur of 1 sample along a dimension: 5 taps, edges repeated (or wrapped around, circular), as Python's ophys_methods._blur
    weights = exp(-(-2:2) .^ 2 / 2);
    weights = weights / sum(weights);
    n = size(values, dimension);
    out = zeros(size(values));
    for k = -2:2
        index = (1:n) + k;
        if circular
            index = mod(index - 1, n) + 1;
        else
            index = min(max(index, 1), n);
        end
        if dimension == 1
            out = out + weights(k + 3) * values(index, :);
        else
            out = out + weights(k + 3) * values(:, index);
        end
    end
end
