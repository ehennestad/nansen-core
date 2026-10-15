function edges = patchEdges(size_, count)
%patchEdges Where count patches of a size start and end (from 0): patch i is edges(i) to edges(i + 1) - 1
    edges = floor((0:count) * size_ / count);
end
