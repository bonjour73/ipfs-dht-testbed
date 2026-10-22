const target = document.getElementById('text-block');
const paragraph = 'Content addressing, Merkle DAGs, peer discovery, provider routing, and block exchange all influence real retrieval behavior in IPFS. '; 
for (let i = 0; i < 800; i++) {
  const p = document.createElement('p');
  p.textContent = `${i + 1}. ${paragraph.repeat(8)}`;
  target.appendChild(p);
}
