workspace "Catalog" "A small catalog." {
    model {
        reader = person "Reader"
        catalog = softwareSystem "Catalog" "Provides catalog entries." {
            !docs documentation
            !adrs decisions
            web = container "Web" "Serves catalog pages." "Java"
            store = container "Store" "Stores catalog entries." "SQL"
            web -> store "Reads entries" "SQL"
        }
        reader -> web "Reads catalog" "HTTPS"
    }
    views {
        systemContext catalog "context" "Catalog context." {
            include *
            autoLayout lr
        }
        container catalog "containers" "Catalog containers." {
            include *
            autoLayout lr
        }
    }
    configuration {
        scope softwaresystem
    }
}
