function ops = opsChanges(ops1, ops0)
%opsChanges Stub of Suite2P's (the same): ops0's fields over ops1's
    ops = ops1;
    for name = reshape(fieldnames(ops0), 1, [])
        ops.(name{1}) = ops0.(name{1});
    end
end
