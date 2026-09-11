package fr.epsi.hogwartspoints

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import fr.epsi.hogwartspoints.model.AddScoreRequest
import fr.epsi.hogwartspoints.model.House
import fr.epsi.hogwartspoints.model.ScoreEntry
import fr.epsi.hogwartspoints.network.ApiClient
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class MainUiState(
    val houses: List<House> = emptyList(),
    val history: List<ScoreEntry> = emptyList(),
    val selectedHouseId: Long? = null,
    val points: Int = 10,
    val reason: String = "",
    val loading: Boolean = false,
    val error: String? = null,
    val message: String? = null
)

class MainViewModel(
    private val api: ApiClient = ApiClient()
) : ViewModel() {
    private val _state = MutableStateFlow(MainUiState())
    val state: StateFlow<MainUiState> = _state.asStateFlow()

    init { refresh() }

    fun refresh() {
        viewModelScope.launch {
            _state.value = _state.value.copy(loading = true, error = null)
            runCatching {
                val houses = api.getHouses()
                val history = api.getScores()
                _state.value.copy(
                    houses = houses.sortedByDescending { it.points },
                    history = history,
                    loading = false,
                    selectedHouseId = _state.value.selectedHouseId ?: houses.firstOrNull()?.id
                )
            }.onSuccess { _state.value = it }
             .onFailure { _state.value = _state.value.copy(loading = false, error = it.message ?: "Erreur réseau") }
        }
    }

    fun selectHouse(id: Long) {
        _state.value = _state.value.copy(selectedHouseId = id)
    }

    fun setPoints(value: Int) {
        _state.value = _state.value.copy(points = value.coerceIn(-100, 100))
    }

    fun setReason(value: String) {
        _state.value = _state.value.copy(reason = value.take(120))
    }

    fun addPoints() {
        val houseId = _state.value.selectedHouseId ?: return
        if (_state.value.points == 0) {
            _state.value = _state.value.copy(error = "Le nombre de points ne peut pas être 0.")
            return
        }
        viewModelScope.launch {
            _state.value = _state.value.copy(loading = true, error = null)
            runCatching {
                api.addScore(
                    AddScoreRequest(
                        houseId = houseId,
                        points = _state.value.points,
                        reason = _state.value.reason.ifBlank { "Décision de Dumbledore" }
                    )
                )
                api.getHouses()
            }.onSuccess { houses ->
                _state.value = _state.value.copy(
                    houses = houses.sortedByDescending { it.points },
                    loading = false,
                    reason = "",
                    message = "Points enregistrés !"
                )
                refresh()
            }.onFailure {
                _state.value = _state.value.copy(loading = false, error = it.message ?: "Impossible d'ajouter les points.")
            }
        }
    }

    fun undoLast() {
        viewModelScope.launch {
            runCatching { api.undoLast() }
                .onSuccess { refresh() }
                .onFailure { _state.value = _state.value.copy(error = it.message ?: "Aucune action à annuler.") }
        }
    }

    fun reset() {
        viewModelScope.launch {
            runCatching { api.reset() }
                .onSuccess { refresh() }
                .onFailure { _state.value = _state.value.copy(error = it.message ?: "Réinitialisation impossible.") }
        }
    }

    fun clearMessage() {
        _state.value = _state.value.copy(message = null)
    }
}
