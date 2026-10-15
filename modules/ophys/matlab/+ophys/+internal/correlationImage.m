function image = correlationImage(stack)
%correlationImage Each pixel's average Pearson correlation with its in-frame 8 neighbours over time, read a chunk of frames at a time
%
%   nansen.internal.localCorrelation, the viewer's correlation projection.
    image = nansen.internal.localCorrelation(stack);
end
