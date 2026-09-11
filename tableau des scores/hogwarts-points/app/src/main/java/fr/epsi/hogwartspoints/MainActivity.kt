package fr.epsi.hogwartspoints

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import fr.epsi.hogwartspoints.model.House

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { HogwartsApp() }
    }
}

private val Navy = Color(0xFF07111F)
private val Gold = Color(0xFFD6AD52)
private val Parchment = Color(0xFFF1E5C7)
private val Burgundy = Color(0xFF641C32)

@Composable
fun HogwartsApp(vm: MainViewModel = viewModel()) {
    val state by vm.state.collectAsState()
    var tab by remember { mutableIntStateOf(0) }
    var showReset by remember { mutableStateOf(false) }

    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Gold,
            secondary = Burgundy,
            background = Navy,
            surface = Color(0xFF0D1B2A)
        )
    ) {
        Scaffold(
            containerColor = Navy,
            bottomBar = {
                NavigationBar(containerColor = Color(0xFF050B14)) {
                    listOf(
                        "Accueil" to Icons.Default.Home,
                        "Ajouter" to Icons.Default.Add,
                        "Historique" to Icons.Default.History,
                        "Réglages" to Icons.Default.Settings
                    ).forEachIndexed { index, item ->
                        NavigationBarItem(
                            selected = tab == index,
                            onClick = { tab = index },
                            icon = { Icon(item.second, null) },
                            label = { Text(item.first) }
                        )
                    }
                }
            }
        ) { padding ->
            when (tab) {
                0 -> HomeScreen(state, vm, Modifier.padding(padding))
                1 -> AddScreen(state, vm, Modifier.padding(padding))
                2 -> HistoryScreen(state, vm, Modifier.padding(padding))
                3 -> SettingsScreen(state, vm, Modifier.padding(padding)) { showReset = true }
            }
        }

        if (showReset) {
            AlertDialog(
                onDismissRequest = { showReset = false },
                title = { Text("Réinitialiser la Coupe ?") },
                text = { Text("Tous les scores reviendront à 0. Cette action est réservée à Dumbledore.") },
                confirmButton = {
                    TextButton(onClick = { vm.reset(); showReset = false }) { Text("Réinitialiser") }
                },
                dismissButton = {
                    TextButton(onClick = { showReset = false }) { Text("Annuler") }
                }
            )
        }

        state.error?.let { error ->
            LaunchedEffect(error) { /* state remains visible for the user */ }
        }
    }
}

@Composable
private fun Header(title: String) {
    Row(
        Modifier.fillMaxWidth().background(Color(0xFF050B14)).padding(16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text("⚜", color = Gold, style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.width(10.dp))
        Text(title, color = Parchment, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun HomeScreen(state: MainUiState, vm: MainViewModel, modifier: Modifier) {
    LazyColumn(modifier.fillMaxSize()) {
        item { Header("Hogwarts Score") }
        item {
            Card(
                Modifier.padding(16.dp).fillMaxWidth(),
                colors = CardDefaults.cardColors(containerColor = Color(0xFF0D1B2A))
            ) {
                Column(Modifier.padding(18.dp)) {
                    Text("« La véritable sagesse est de savoir que l'on ne sait rien. »", color = Parchment)
                    Text("— Dumbledore", color = Gold, modifier = Modifier.padding(top = 8.dp))
                }
            }
        }
        item { Text("Classement des maisons", color = Parchment, style = MaterialTheme.typography.headlineSmall, modifier = Modifier.padding(16.dp)) }
        items(state.houses) { house ->
            HouseRow(house, selected = false, onClick = { vm.selectHouse(house.id) })
        }
        item {
            Row(Modifier.padding(16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(onClick = vm::undoLast, modifier = Modifier.weight(1f)) {
                    Text("Annuler")
                }
                Button(onClick = vm::refresh, modifier = Modifier.weight(1f)) {
                    Icon(Icons.Default.Refresh, null)
                    Spacer(Modifier.width(4.dp))
                    Text("Actualiser")
                }
            }
        }
    }
}

@Composable
private fun HouseRow(house: House, selected: Boolean, onClick: () -> Unit) {
    val accent = when (house.name) {
        "Gryffondor" -> Color(0xFF9E1B32)
        "Serpentard" -> Color(0xFF176B45)
        "Poufsouffle" -> Color(0xFFB88A00)
        else -> Color(0xFF1759A5)
    }
    Card(
        Modifier.padding(horizontal = 16.dp, vertical = 6.dp).fillMaxWidth().clickable(onClick = onClick),
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = accent.copy(alpha = .9f))
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("✦", color = Color.White, style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.width(12.dp))
            Text(house.name, color = Color.White, modifier = Modifier.weight(1f), fontWeight = FontWeight.Bold)
            Text("${house.points} pts", color = Color.White)
        }
    }
}

@Composable
private fun AddScreen(state: MainUiState, vm: MainViewModel, modifier: Modifier) {
    LazyColumn(modifier.fillMaxSize().padding(bottom = 12.dp)) {
        item { Header("Ajouter des points") }
        item {
            Column(Modifier.padding(16.dp)) {
                Text("Maison", color = Parchment, style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(10.dp))
                state.houses.forEach { house ->
                    HouseRow(house, state.selectedHouseId == house.id) { vm.selectHouse(house.id) }
                }
                Spacer(Modifier.height(16.dp))
                Text("Nombre de points", color = Parchment)
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    OutlinedButton(onClick = { vm.setPoints(state.points - 5) }) { Text("−5") }
                    Text("${state.points}", color = Gold, style = MaterialTheme.typography.headlineMedium, modifier = Modifier.weight(1f))
                    OutlinedButton(onClick = { vm.setPoints(state.points + 5) }) { Text("+5") }
                }
                OutlinedTextField(
                    value = state.reason,
                    onValueChange = vm::setReason,
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("Motif") },
                    placeholder = { Text("Victoire, défi, entraide…") }
                )
                Spacer(Modifier.height(16.dp))
                Button(onClick = vm::addPoints, modifier = Modifier.fillMaxWidth(), enabled = !state.loading) {
                    Text("Ajouter les points")
                }
                state.error?.let {
                    Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 10.dp))
                }
            }
        }
    }
}

@Composable
private fun HistoryScreen(state: MainUiState, vm: MainViewModel, modifier: Modifier) {
    LazyColumn(modifier.fillMaxSize()) {
        item { Header("Historique") }
        items(state.history) { entry ->
            ListItem(
                headlineContent = { Text("${entry.houseName}  ${if (entry.points >= 0) "+" else ""}${entry.points} pts", color = Parchment) },
                supportingContent = { Text("${entry.reason}\n${entry.createdAt}", color = Color.LightGray) },
                modifier = Modifier.padding(horizontal = 8.dp)
            )
            HorizontalDivider()
        }
        item {
            if (state.history.isEmpty()) {
                Text("Aucune action pour le moment.", color = Color.LightGray, modifier = Modifier.padding(24.dp))
            }
        }
    }
}

@Composable
private fun SettingsScreen(state: MainUiState, vm: MainViewModel, modifier: Modifier, onReset: () -> Unit) {
    Column(modifier.fillMaxSize()) {
        Header("Paramètres")
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text("Administration", color = Parchment, style = MaterialTheme.typography.titleLarge)
            Text("Dumbledore peut réinitialiser la Coupe ou annuler la dernière décision.", color = Color.LightGray)
            OutlinedButton(onClick = vm::undoLast, modifier = Modifier.fillMaxWidth()) {
                Text("Annuler la dernière action")
            }
            Button(
                onClick = onReset,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = Burgundy)
            ) {
                Text("Réinitialiser les scores")
            }
            Text("Version 1.0.0 • Kotlin • Ktor • PostgreSQL", color = Color.Gray)
        }
    }
}
