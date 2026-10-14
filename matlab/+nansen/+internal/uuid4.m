function id = uuid4()
%uuid4 A random version-4 UUID, from a private random stream (the global one is left alone)
    stream = RandStream("dsfmt19937", Seed="shuffle");
    digits = randi(stream, [0, 15], 1, 32);
    digits(13) = 4;
    digits(17) = 8 + mod(digits(17), 4);
    hex = lower(dec2hex(digits))';
    id = string([hex(1:8), '-', hex(9:12), '-', hex(13:16), '-', hex(17:20), '-', hex(21:32)]);
end
