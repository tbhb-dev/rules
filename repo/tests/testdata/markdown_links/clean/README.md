# Clean tree

See [the guide][ref], [again](docs/guide.md), [the folder](docs/sub), and [the top](#clean-tree).
External [site](https://example.com/missing.md) and [mail](mailto:a@example.com) are skipped.
Code such as `[x](nowhere.md)` is skipped too.

```text
[y](nowhere.md)
```

A [query](docs/guide.md?plain=1) resolves.

    [z](nowhere.md)

[ref]: docs/guide.md
