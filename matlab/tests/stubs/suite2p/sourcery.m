function [ops, stat, model] = sourcery(ops)
%sourcery Stub of Suite2P's: two ROIs, in the registered range, once the binary file is there
    assert(isfile(ops.RegFile), "no binary file %s", ops.RegFile)
    stat = struct("ypix", {[1; 1; 2], 4}, "xpix", {[2; 3; 2], 4});
    model = struct();
end
