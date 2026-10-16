function image = meanClahe(stack)
%meanClahe dev's Mean CLAHE projection (stack.zproject.meanclahe) of a height x width x frames stack
%
%   The mean over the frames, normalised to 0..1 (from its smallest to its
%   largest finite value), contrast-limited adaptive histogram equalisation
%   (dev's adapthisteq with 32 x 32 tiles, clip limit 0.015 and a Rayleigh
%   distribution, written out in nansen.internal.claheImage, no toolbox),
%   scaled back to the mean's range and, for a stack of whole numbers,
%   rounded as its type (half away from zero, cut at the type's range). An image smaller than 32 pixels
%   either way is the normalised mean, as dev's; a flat one, the mean.
%   Python's nansen.frames.mean_clahe gives the same values.
    if ~isa(stack, "nansen.Stack")
        stack = nansen.Stack.fromArray(stack, 3);
    end
    average = nansen.internal.meanImage(stack);
    image = nansen.internal.claheImage(average);
    finite = average(isfinite(average));
    equalised = ~isempty(finite) && max(finite) > min(finite) && size(average, 1) >= 32 && size(average, 2) >= 32;
    className = char(stack.ClassName);
    if equalised && any(strcmp(className, ["uint8", "uint16", "uint32", "uint64", "int8", "int16", "int32", "int64"]))
        image = min(max(sign(image) .* floor(abs(image) + 0.5), double(intmin(className))), double(intmax(className)));
    end
end
