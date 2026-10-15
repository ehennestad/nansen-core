"""File adapters of a module's layout, to import: the documents in adapters/ and file-adapters/, the code in python/."""


class TwoAdapter:
    columns = 2

    def read(self, path):
        with open(path, encoding="utf-8") as f:
            return [line.split()[:self.columns] for line in f]

    def write(self, path, data):
        with open(path, "w", encoding="utf-8") as f:
            f.write("".join(" ".join(map(str, row)) + "\n" for row in data))


class ThreeAdapter(TwoAdapter):
    columns = 3

    def read(self, path):
        return super().read(path)

    def write(self, path, data):
        super().write(path, data)
