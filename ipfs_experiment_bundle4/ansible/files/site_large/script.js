const target = document.getElementById('records');
const sentence = 'This client-side workload intentionally creates a larger DOM so the page-load metric reflects both retrieval and browser-side work. ';
for (let i = 0; i < 400; i++) {
  const div = document.createElement('div');
  div.className = 'card';
  div.innerHTML = `<h2>Record ${i + 1}</h2><p>${sentence.repeat(10)}</p>`;
  target.appendChild(div);
}
