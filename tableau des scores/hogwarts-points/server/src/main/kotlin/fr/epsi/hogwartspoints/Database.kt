package fr.epsi.hogwartspoints

import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
import org.jetbrains.exposed.sql.*
import org.jetbrains.exposed.sql.transactions.transaction

object Houses : Table("houses") {
    val id = long("id").autoIncrement()
    val name = varchar("name", 30).uniqueIndex()
    val color = varchar("color", 20)
    override val primaryKey = PrimaryKey(id)
}

object Scores : Table("scores") {
    val id = long("id").autoIncrement()
    val houseId = long("house_id").references(Houses.id)
    val points = integer("points")
    val reason = varchar("reason", 120)
    val createdAt = long("created_at")
    override val primaryKey = PrimaryKey(id)
}

class DatabaseFactory(private val database: Database) {
    fun init() {
        transaction(database) {
            SchemaUtils.create(Houses, Scores)
            if (Houses.selectAll().count() == 0L) {
                Houses.insert {
                    it[id] = 1
                    it[name] = "Gryffondor"
                    it[color] = "#9E1B32"
                }
                Houses.insert {
                    it[id] = 2
                    it[name] = "Serpentard"
                    it[color] = "#176B45"
                }
                Houses.insert {
                    it[id] = 3
                    it[name] = "Poufsouffle"
                    it[color] = "#B88A00"
                }
                Houses.insert {
                    it[id] = 4
                    it[name] = "Serdaigle"
                    it[color] = "#1759A5"
                }
            }
        }
    }

    companion object {
        fun fromEnvironment(): DatabaseFactory {
            val url = System.getenv("DATABASE_URL")
                ?: "jdbc:postgresql://localhost:5432/hogwarts"
            val user = System.getenv("DATABASE_USER") ?: "hogwarts"
            val password = System.getenv("DATABASE_PASSWORD") ?: "hogwarts_dev"

            val config = HikariConfig().apply {
                jdbcUrl = url
                username = user
                this.password = password
                driverClassName = "org.postgresql.Driver"
                maximumPoolSize = 5
            }
            return DatabaseFactory(Database.connect(HikariDataSource(config)))
        }

        fun forTest(url: String): DatabaseFactory {
            return DatabaseFactory(Database.connect(url, driver = "org.h2.Driver"))
        }
    }
}
