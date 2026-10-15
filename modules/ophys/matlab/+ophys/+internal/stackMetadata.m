function metadata = stackMetadata(frameRate, pixelSize, zStep)
%stackMetadata A stack's metadata: frameRate, pixelSize ([x, y]) and zStep, those given as positive finite numbers
%
%   Each is rounded to 6 decimals, floor(v * 1e6 + 0.5) / 1e6; one left
%   out, empty or NaN is not there. As Python's ophys_adapters.stack_metadata.
    if nargin < 2
        pixelSize = [];
    end
    if nargin < 3
        zStep = [];
    end
    usable = @(v) isnumeric(v) && ~isempty(v) && all(isfinite(v)) && all(v > 0);
    rounded = @(v) floor(double(v) * 1e6 + 0.5) / 1e6;
    metadata = struct();
    if isscalar(frameRate) && usable(frameRate)
        metadata.frameRate = rounded(frameRate);
    end
    if numel(pixelSize) == 2 && usable(pixelSize)
        metadata.pixelSize = reshape(rounded(pixelSize), 1, 2);
    end
    if isscalar(zStep) && usable(zStep)
        metadata.zStep = rounded(zStep);
    end
end
