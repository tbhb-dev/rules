workspace "Catalog" "A small catalog." {
    !script groovy {
        println "noise: a clean workspace may print this"
    }
    model {
        reader = person "Reader" "Reads the catalog."
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
