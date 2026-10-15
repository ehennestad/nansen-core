function sigma = noiseLevel(trace)
%noiseLevel The noise of a trace from its frame-to-frame differences: median(|diff|) / (0.6745 * sqrt(2)); NaN if any value is
    if numel(trace) < 2 || any(isnan(trace))
        sigma = NaN;
        return
    end
    ordered = sort(abs(diff(trace(:))));
    n = numel(ordered);
    if mod(n, 2) == 1
        middle = ordered((n + 1) / 2);
    else
        middle = (ordered(n / 2) + ordered(n / 2 + 1)) / 2;
    end
    sigma = middle / (0.6745 * sqrt(2));
end
